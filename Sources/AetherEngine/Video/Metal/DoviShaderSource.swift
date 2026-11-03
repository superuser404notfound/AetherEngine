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

/* ---- per-frame MMR table (buffer 3): [Y, Cb, Cr][piece 0..7][constant, 21 coefficients] ---- */
#define DOVI_MMR_TABLE_PIECE_STRIDE      22
#define DOVI_MMR_TABLE_COMPONENT_STRIDE  (8 * DOVI_MMR_TABLE_PIECE_STRIDE)

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
// `k` is this component's slice of the per-frame MMR table (`populateMmrTable`): per piece the
// constant then the 21 coefficients, each float(coef) * 2^-coef_shift computed once on the CPU. That
// is the value this function used to form per term in the loop (a power-of-two scale is exact), so
// the sum is unchanged bit for bit, without an int-to-float conversion and a multiply per term.
static inline float dovi_eval_mmr(
    constant struct DoviPolynomialParams &curve,
    device const float* k,
    int piece,
    float y_norm, float u_norm, float v_norm)
{
    // y_norm, u_norm and v_norm are already clamped to their components' pivot ranges.
    device const float* c = k + piece * DOVI_MMR_TABLE_PIECE_STRIDE;
    float s = c[0];

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
            s = fma(c[1u + o * 7u + uint(k)], t[k], s);
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
    device const float* mmr,
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
    // The clamp is in float, before the conversion: an MMR result far outside the range would overflow int.
    return int(rint(clamp(pred_norm * float(bl_max) * float(vdr_scale), 0.0f, float(vdr_max))));
}

/* ============================================================================
   Inverse NLQ
   ========================================================================= */

// The inverse linear-deadzone quantiser depends on the 10-bit EL code alone, so the composer evaluates it
// once per frame for all 1024 codes of each component (`DoviFelComposer.inverseNlq`, where the reading and
// its reasons are written down) and the kernels index that table: nlq_lut[component * 1024 + code], in VDR
// code units, Y then Cb then Cr. The 64-bit products it replaces were most of the residual's cost.
static inline int dovi_inv_nlq(device const int* nlq_lut, uint component, int el_code) {
    return nlq_lut[component * 1024u + uint(clamp(el_code, 0, 1023))];
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

// EL upsampling: Annex B for the 2:1 chroma, bilinear from explicit texel reads with exact weights elsewhere.
//
// Chroma, at the 4:2:0 sites, when the EL is half the base layer's size in both axes (the Profile 7
// enhancement layer): the default spatial resampling filter of ETSI GS CCM 001 Annex B.3, in integers
// (`dovi_annexb_chroma`). The RPU does not carry the encoder's own filter (el_spatial_resampling_filter_flag
// only says one was used), and the standard treats resampling as non-normative, but Annex B gives a default
// and it is the one reading every EL plane agrees on: vertical first, centred, then horizontal, co-sited.
// Measured on the Mac against an integer model written from the standard, the composed chroma lands within
// +-1 of 12-bit code on all chroma samples of the corpus frames bar 3 Cb samples of one clip (largest error 2), where the one-fetch co-sited bilinear it
// replaces reached 83 to 99% (the worst, a high-residual film clip, 83 / 90% for Cb / Cr). Any other
// ratio (an EL at the base layer's size, which is an exact texel read) takes the exact-weight bilinear read below.
//
// Luma is still the centred bilinear read (one gather). An Annex B luma (4 vertical by 8 horizontal taps) is
// compiled in only under DEBUG (`DOVI_DEBUG_EL_VARIANTS`), behind a flag, so its GPU cost can be measured
// before anyone decides to ship it. Against the Dolby masters it helps on hard edges only.
//
// The bilinear read: el_spatial_resampling_filter_flag advertises that the encoder used its own
// separable filter, whose taps the RPU does not carry, so no bit-exact inverse
// is available from the stream. Against the DoViBaker oracle on a fine-detail set (gratings, zone plate,
// band-limited noise) a 4-fetch Catmull-Rom bought about 0.7% of per-pixel error sd over bilinear, with chroma
// unchanged, for four times the EL reads.
//
// Not the hardware sampler: its bilinear weights are fixed point, so the interpolated code could land one
// off the exact value (the CPU model saw it), and rounding that with rint() sent every exact half to the
// even neighbour. A 2:1 EL interpolates at quarter weights, where halves are common (two texels 2 apart
// mod 4), so ties-to-even was a parity-dependent bias. Here the weights for a 2:1 or 1:1 EL are exact quarters,
// halves or zero, every product and sum of 10-bit codes at those weights is exact in float, and the caller
// rounds half up.

// One axis: the lower EL texel index and the fraction towards the next texel for base-layer sample n.
// `centre` 0.5 puts both grids' samples at their pixel centres (luma: n_el = (n + 1/2) * el / bl - 1/2);
// 0 co-sites the first samples (chroma: n_el = n * el / bl). For the 2:1 and 1:1 grids streams use,
// el / bl is 0.5 or 1, so every term is exact in float.
static inline int dovi_el_axis(uint n, float ratio, float centre, thread float &frac) {
    float u = (float(n) + centre) * ratio - centre;
    float i = floor(u);
    frac = u - i;
    return int(i);
}

// Bilinear EL luma code at base-layer pixel `site` of a `bl_size` plane, edges clamped. One gather fetches the
// 2x2 footprint: the point between the four texel centres selects it and sits half a texel from any footprint
// boundary. A gather measured cheaper here than four reads (UHD luma 0.41 ms against 0.45 ms on an M4 Pro).
static inline float dovi_upsample_el(texture2d<ushort, access::sample> tex, uint2 site,
                                     uint2 bl_size, uint2 el_size) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    float fx, fy;
    int x0 = dovi_el_axis(site.x, float(el_size.x) / float(bl_size.x), 0.5f, fx);
    int y0 = dovi_el_axis(site.y, float(el_size.y) / float(bl_size.y), 0.5f, fy);
    // Gather order: (x0, y1), (x1, y1), (x1, y0), (x0, y0).
    float4 c = float4(tex.gather(s, float2(float(x0 + 1), float(y0 + 1))) >> 6);
    float top = c.w * (1.0f - fx) + c.z * fx;
    float bot = c.x * (1.0f - fx) + c.y * fx;
    return top * (1.0f - fy) + bot * fy;
}

// Bilinear EL chroma codes (Cb, Cr) at base chroma sample `site`, co-sited, edges clamped. Four reads of the
// interleaved plane return both components each, which measured cheaper than a gather per component.
static inline float2 dovi_upsample_el_uv(texture2d<ushort, access::read> tex, uint2 site,
                                         uint2 bl_size, uint2 el_size) {
    float fx, fy;
    int x0 = dovi_el_axis(site.x, float(el_size.x) / float(bl_size.x), 0.0f, fx);
    int y0 = dovi_el_axis(site.y, float(el_size.y) / float(bl_size.y), 0.0f, fy);
    int xm = int(el_size.x) - 1, ym = int(el_size.y) - 1;
    uint xa = uint(clamp(x0, 0, xm)), xb = uint(clamp(x0 + 1, 0, xm));
    uint ya = uint(clamp(y0, 0, ym)), yb = uint(clamp(y0 + 1, 0, ym));
    float2 c00 = float2(tex.read(uint2(xa, ya)).rg >> 6);
    float2 c10 = float2(tex.read(uint2(xb, ya)).rg >> 6);
    float2 c01 = float2(tex.read(uint2(xa, yb)).rg >> 6);
    float2 c11 = float2(tex.read(uint2(xb, yb)).rg >> 6);
    float2 top = c00 * (1.0f - fx) + c10 * fx;
    float2 bot = c01 * (1.0f - fx) + c11 * fx;
    return top * (1.0f - fy) + bot * fy;
}

// Round half up: the interpolated EL code back to an integer code for the inverse NLQ.
static inline int dovi_el_code(float v) {
    return int(floor(v + 0.5f));
}

// The EL's integer code at a texel (clamped at the edges, like the standard's edge replication). The EL planes are
// bound as integer textures (the stored P010 word >> 6); the Annex B filters below take their codes only through
// these readers, so no filter on the EL path reads through a float sampler.
template <access A>
static inline int dovi_el_code_1(texture2d<ushort, A> tex, int2 p, int2 size) {
    p = clamp(p, int2(0), size - 1);
    return int(tex.read(uint2(p)).r >> 6);
}

template <access A>
static inline int2 dovi_el_code_2(texture2d<ushort, A> tex, int2 p, int2 size) {
    p = clamp(p, int2(0), size - 1);
    return int2(tex.read(uint2(p)).rg >> 6);
}

// True when a plane of `el` texels is the half-size EL of a base-layer plane of `bl` samples (a base plane of
// odd size has a half-size plane of ceil(bl / 2) texels, so `bl` may be one less than twice `el`).
static inline bool dovi_el_is_half(uint bl, uint el) {
    return el > 0u && (bl == 2u * el || bl + 1u == 2u * el);
}

// ETSI GS CCM 001 Annex B.3, horizontal: output 2m is the sample m, output 2m+1 is this 8-tap filter over
// the samples m-3 .. m+4. Taps sum to 4096; the result is rounded (+2048 >> 12) and clamped to 16 bits.
constant int dovi_annexb_h_taps[8] = { 22, 94, -524, 2456, 2456, -524, 94, 22 };

// Chroma, vertical: output row 2n = (64 e[n-1] + 192 e[n] + 128) >> 8, row 2n+1 = (192 e[n] + 64 e[n+1] + 128) >> 8,
// both in the EL chroma plane at column `cx`. Cb in .x, Cr in .y.
template <typename Tex>
static inline int2 dovi_annexb_v_chroma(Tex tex, int cx, int y, int2 size) {
    int n = y >> 1;
    bool odd = (y & 1) != 0;
    int2 a = dovi_el_code_2(tex, int2(cx, odd ? n : n - 1), size);
    int2 b = dovi_el_code_2(tex, int2(cx, odd ? n + 1 : n), size);
    return clamp(((odd ? (192 * a + 64 * b) : (64 * a + 192 * b)) + 128) >> 8, int2(0), int2(65535));
}

// The Annex B resampled EL chroma code (Cb, Cr) at base chroma site `site`: vertical first, then horizontal on
// the vertical results, integer all the way. `size` is the EL chroma plane's size.
template <typename Tex>
static inline int2 dovi_annexb_chroma(Tex tex, uint2 site, int2 size) {
    int m = int(site.x >> 1);
    int y = int(site.y);
    if ((site.x & 1u) == 0u) {
        return dovi_annexb_v_chroma(tex, m, y, size);
    }
    int2 acc = int2(2048);
    for (int k = 0; k < 8; ++k) {
        acc += dovi_annexb_h_taps[k] * dovi_annexb_v_chroma(tex, m + k - 3, y, size);
    }
    return clamp(acc >> 12, int2(0), int2(65535));
}

#ifdef DOVI_DEBUG_EL_VARIANTS
#define DOVI_FLAG_DEBUG_COSITED_EL_CHROMA 0x4u /* A/B: the pre-Annex B co-sited bilinear chroma read */
#define DOVI_FLAG_DEBUG_ANNEXB_EL_LUMA    0x8u /* measurement: Annex B EL luma (4 x 8 taps) */

// Luma, vertical: row 2n = (-3 e[n-2] + 29 e[n-1] + 111 e[n] - 9 e[n+1] + 64) >> 7,
// row 2n+1 = (-9 e[n-1] + 111 e[n] + 29 e[n+1] - 3 e[n+2] + 64) >> 7.
template <typename Tex>
static inline int dovi_annexb_v_luma(Tex tex, int cx, int y, int2 size) {
    int n = y >> 1;
    int v;
    if ((y & 1) == 0) {
        v = -3 * dovi_el_code_1(tex, int2(cx, n - 2), size) + 29 * dovi_el_code_1(tex, int2(cx, n - 1), size)
          + 111 * dovi_el_code_1(tex, int2(cx, n), size) - 9 * dovi_el_code_1(tex, int2(cx, n + 1), size);
    } else {
        v = -9 * dovi_el_code_1(tex, int2(cx, n - 1), size) + 111 * dovi_el_code_1(tex, int2(cx, n), size)
          + 29 * dovi_el_code_1(tex, int2(cx, n + 1), size) - 3 * dovi_el_code_1(tex, int2(cx, n + 2), size);
    }
    return clamp((v + 64) >> 7, 0, 65535);
}

template <typename Tex>
static inline int dovi_annexb_luma(Tex tex, uint2 gid, int2 size) {
    int m = int(gid.x >> 1);
    int y = int(gid.y);
    if ((gid.x & 1u) == 0u) {
        return dovi_annexb_v_luma(tex, m, y, size);
    }
    int acc = 2048;
    for (int k = 0; k < 8; ++k) {
        acc += dovi_annexb_h_taps[k] * dovi_annexb_v_luma(tex, m + k - 3, y, size);
    }
    return clamp(acc >> 12, 0, 65535);
}
#endif

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
// The luma body is one template over the luma textures, so the pool kernel and the in-place kernel
// share it: the pool kernel reads and writes two planes, the in-place kernel one plane it both reads and writes.
template <typename YIn, typename YOut>
static inline void dovi_compose_luma_plane(
    YIn                                    bl_y_tex,
    texture2d<ushort, access::read>        bl_uv_tex,
    texture2d<ushort, access::sample>       el_y_tex,
    YOut                                   out_y_tex,
    constant struct DoviMetalParams&       params,
    constant float*                        luma_lut,
    device const int*                      nlq_lut,
    device const float*                    mmr_table,
    uint2                                  gid)
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
        pred = dovi_eval_curve(params.poly_y, mmr_table,
                               params.poly_y, params.poly_cb, params.poly_cr, bl_y,
                               y_norm, u_norm, v_norm, params.bl_max + 1u);
    }
    int vdr_y = dovi_denormalize(pred, params.bl_max + 1u, params.vdr_scale, params.vdr_max);

    if ((params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u &&
        params.nlq_y.nlq_method == DOVI_NLQ_METHOD_LINEAR &&
        params.nlq_y.nlq_scale != 0) {
        int el_code;
#ifdef DOVI_DEBUG_EL_VARIANTS
        if ((params.flags & DOVI_FLAG_DEBUG_ANNEXB_EL_LUMA) != 0u &&
            dovi_el_is_half(params.bl_width, params.el_width) && dovi_el_is_half(params.bl_height, params.el_height)) {
            el_code = dovi_annexb_luma(el_y_tex, gid, int2(params.el_width, params.el_height));
        } else
#endif
        {
            // Centre-aligned: luma samples sit at pixel centres on both grids.
            float el = dovi_upsample_el(el_y_tex, gid, uint2(params.bl_width, params.bl_height),
                                        uint2(params.el_width, params.el_height));
            el_code = dovi_el_code(el);
        }
        vdr_y += dovi_inv_nlq(nlq_lut, 0u, el_code);
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

kernel void dovi_compose_luma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::sample>       el_y_tex      [[texture(2)]],
    texture2d<ushort, access::write>       out_y_tex     [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant float*                        luma_lut      [[buffer(1)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const float*                    mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    dovi_compose_luma_plane(bl_y_tex, bl_uv_tex, el_y_tex, out_y_tex, params, luma_lut, nlq_lut, mmr_table, gid);
}

/* The composed chroma at one 4:2:0 site, before quantisation, as clamped VDR codes. The 4:2:0 kernel
   writes it on its own grid; the 4:2:2 and 4:4:4 kernels take their samples from these sites, so
   every chroma format is the same composition at the 4:2:0 sites, stepped up. */
struct DoviChromaSite {
    int cb;
    int cr;
};

// The chroma plane is read and written through one accessor per texture type, so the pool kernels
// (16-bit texels) and the in-place kernel (32-bit texels, one Cb and Cr pair each) share one body.
// The pool types are specialised here; the in-place type is specialised in the in-place block, which
// is compiled only on devices that run the in-place kernels. The shared bodies below name the
// accessor through the template, so they pick the specialisation at instantiation.
template <typename Tex>
struct dovi_uv_plane;

template <>
struct dovi_uv_plane<texture2d<ushort, access::read> > {
    static ushort4 load(texture2d<ushort, access::read> tex, uint2 p)
    {
        return tex.read(p);
    }
};

template <>
struct dovi_uv_plane<texture2d<ushort, access::write> > {
    static void store(texture2d<ushort, access::write> tex, ushort4 value, uint2 p)
    {
        tex.write(value, p);
    }
};

// Chroma: both chroma planes in one pass, since an MMR curve for Cb and for Cr
// reads the same three base-layer components.
template <typename UVIn>
static inline DoviChromaSite dovi_chroma_site(
    uint2                                  site,
    texture2d<ushort, access::read>        bl_y_tex,
    UVIn                                   bl_uv_tex,
    texture2d<ushort, access::read>       el_uv_tex,
    constant struct DoviMetalParams        &params,
    device const int*                      nlq_lut,
    device const float*                    mmr_table)
{
    uint uv_width = (params.bl_width + 1u) / 2u;
    uint uv_height = (params.bl_height + 1u) / 2u;

    // Base-layer luma at the chroma site, for the cross-component terms: [1 2 1]
    // around the even column in each of the cell's two rows, then the rows
    // averaged, in integers, edges clamped. This is DoViBaker's reading, and
    // Dolby-encoded streams agree with it: on one with order-3 MMR chroma the
    // coded residual matches it at about half the error of the plain vertical
    // 2-tap this kernel used before.
    uint lx = min(site.x * 2u, params.bl_width - 1u);
    uint lxl = lx > 0u ? lx - 1u : 0u;
    uint lxr = min(lx + 1u, params.bl_width - 1u);
    int bl_y = 0;
    for (uint r = 0u; r < 2u; ++r) {
        uint ly = min(site.y * 2u + r, params.bl_height - 1u);
        int row = int(bl_y_tex.read(uint2(lxl, ly)).r >> 6)
                + 2 * int(bl_y_tex.read(uint2(lx, ly)).r >> 6)
                + int(bl_y_tex.read(uint2(lxr, ly)).r >> 6);
        bl_y += (row + 2) >> 2;
    }
    bl_y = (bl_y + 1) >> 1;

    ushort4 bl_uv = dovi_uv_plane<UVIn>::load(bl_uv_tex, site);
    int bl_cb = int(bl_uv.r >> 6);
    int bl_cr = int(bl_uv.g >> 6);

    float y_norm = float(bl_y) / float(params.bl_max + 1u);
    float u_norm = float(bl_cb) / float(params.bl_max + 1u);
    float v_norm = float(bl_cr) / float(params.bl_max + 1u);

    float pred_cb = dovi_eval_curve(params.poly_cb, mmr_table + DOVI_MMR_TABLE_COMPONENT_STRIDE,
                                    params.poly_y, params.poly_cb, params.poly_cr, bl_cb,
                                    y_norm, u_norm, v_norm, params.bl_max + 1u);
    float pred_cr = dovi_eval_curve(params.poly_cr, mmr_table + 2 * DOVI_MMR_TABLE_COMPONENT_STRIDE,
                                    params.poly_y, params.poly_cb, params.poly_cr, bl_cr,
                                    y_norm, u_norm, v_norm, params.bl_max + 1u);

    int vdr_cb = dovi_denormalize(pred_cb, params.bl_max + 1u, params.vdr_scale, params.vdr_max);
    int vdr_cr = dovi_denormalize(pred_cr, params.bl_max + 1u, params.vdr_scale, params.vdr_max);

    if ((params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u) {
        bool cb_active = (params.nlq_cb.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cb.nlq_scale != 0);
        bool cr_active = (params.nlq_cr.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cr.nlq_scale != 0);
        if (cb_active || cr_active) {
            // Chroma comes from the EL by the Annex B filter when the EL is half the base layer in both axes
            // (its default resampling filter, see "Enhancement layer upsampling"); any other ratio, or the
            // DEBUG co-sited A/B variant, takes the exact-weight bilinear read.
            int2 el_uv_size = int2(int((params.el_width + 1u) / 2u), int((params.el_height + 1u) / 2u));
            bool annexb = dovi_el_is_half(uv_width, uint(el_uv_size.x)) && dovi_el_is_half(uv_height, uint(el_uv_size.y));
#ifdef DOVI_DEBUG_EL_VARIANTS
            if ((params.flags & DOVI_FLAG_DEBUG_COSITED_EL_CHROMA) != 0u) {
                annexb = false;
            }
#endif
            int2 el_code;
            if (annexb) {
                el_code = dovi_annexb_chroma(el_uv_tex, site, el_uv_size);
            } else {
                // The pre-Annex B read, kept for the ratios the standard's filter does not cover and for the
                // DEBUG A/B: chroma co-sited with the top-left luma sample (chroma location type 2), so base
                // chroma sample n sits at EL chroma texel n * el / bl; bilinear from four explicit reads,
                // same-resolution EL is an exact texel read.
                float2 el = dovi_upsample_el_uv(el_uv_tex, site, uint2(uv_width, uv_height), uint2(el_uv_size));
                el_code = int2(dovi_el_code(el.x), dovi_el_code(el.y));
            }
            if (cb_active) {
                vdr_cb += dovi_inv_nlq(nlq_lut, 1u, el_code.x);
            }
            if (cr_active) {
                vdr_cr += dovi_inv_nlq(nlq_lut, 2u, el_code.y);
            }
        }
    }

    DoviChromaSite out;
    out.cb = clamp(vdr_cb, 0, int(params.vdr_max));
    out.cr = clamp(vdr_cr, 0, int(params.vdr_max));
    return out;
}

template <typename UVOut>
static inline void dovi_write_chroma(
    UVOut                                  out_uv_tex,
    uint2                                  gid,
    int                                    vdr_cb,
    int                                    vdr_cr,
    constant struct DoviMetalParams        &params)
{
    int out_cb = dovi_quantize(vdr_cb, params.vdr_scale, params.dither_mode,
                               dovi_dither(gid, params.frame_index, uint2(1u, 0u)), 64, 960);
    int out_cr = dovi_quantize(vdr_cr, params.vdr_scale, params.dither_mode,
                               dovi_dither(gid, params.frame_index, uint2(1u, 1u)), 64, 960);

    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        dovi_uv_plane<UVOut>::store(out_uv_tex, ushort4(ushort(vdr_cb << 4), ushort(vdr_cr << 4), 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        dovi_uv_plane<UVOut>::store(out_uv_tex, ushort4(ushort(dovi_full_precision(vdr_cb, params.vdr_scale, 64, 960)),
                                                           ushort(dovi_full_precision(vdr_cr, params.vdr_scale, 64, 960)), 0, 0), gid);
        return;
    }
    dovi_uv_plane<UVOut>::store(out_uv_tex, ushort4(ushort(out_cb << 6), ushort(out_cr << 6), 0, 0), gid);
}

// The 4:2:0 chroma body, shared by the pool kernel and the in-place kernel. Each thread reads its own
// chroma sample and writes it back, and reads base-layer luma only, so the in-place write cannot reach a
// neighbour's read.
template <typename UVIn, typename UVOut>
static inline void dovi_compose_chroma_plane(
    texture2d<ushort, access::read>        bl_y_tex,
    UVIn                                   bl_uv_tex,
    texture2d<ushort, access::read>       el_uv_tex,
    UVOut                                  out_uv_tex,
    constant struct DoviMetalParams&       params,
    device const int*                      nlq_lut,
    device const float*                    mmr_table,
    uint2                                  gid)
{
    uint uv_width = (params.bl_width + 1u) / 2u;
    uint uv_height = (params.bl_height + 1u) / 2u;

    if (gid.x >= uv_width || gid.y >= uv_height) {
        return;
    }

    DoviChromaSite site = dovi_chroma_site(gid, bl_y_tex, bl_uv_tex, el_uv_tex, params, nlq_lut, mmr_table);
    dovi_write_chroma(out_uv_tex, gid, site.cb, site.cr, params);
}

kernel void dovi_compose_chroma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::read>       el_uv_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const float*                    mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    dovi_compose_chroma_plane(bl_y_tex, bl_uv_tex, el_uv_tex, out_uv_tex, params, nlq_lut, mmr_table, gid);
}

// A 4:2:0 site as the output holds it: quantised and clamped to video range. The step-up kernels mean
// these, not the unclamped codes, so a site past the range does not pull its neighbours' means off
// the picture the 4:2:0 output would show.
static inline DoviChromaSite dovi_output_site(
    uint2                                  site,
    texture2d<ushort, access::read>        bl_y_tex,
    texture2d<ushort, access::read>        bl_uv_tex,
    texture2d<ushort, access::read>        el_uv_tex,
    constant struct DoviMetalParams        &params,
    device const int*                      nlq_lut,
    device const float*                    mmr_table)
{
    DoviChromaSite s = dovi_chroma_site(site, bl_y_tex, bl_uv_tex, el_uv_tex, params, nlq_lut, mmr_table);
    int lo = int(64u * params.vdr_scale);
    int hi = int(960u * params.vdr_scale);
    s.cb = clamp(s.cb, lo, hi);
    s.cr = clamp(s.cr, lo, hi);
    return s;
}

// 4:2:2 has the luma's full height. A row on a 4:2:0 site is that site's composition; a row between
// two sites is their mean, the co-sited step up that the 4:2:0 phase implies (copy on the site row,
// half way between the rows either side). Rounded up, so with dither off an exact site row comes back unchanged.
kernel void dovi_compose_chroma_422(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::read>        el_uv_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const float*                    mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width = (params.bl_width + 1u) / 2u;
    uint uv_height = (params.bl_height + 1u) / 2u;

    if (gid.x >= uv_width || gid.y >= params.bl_height) {
        return;
    }

    uint site_y = gid.y / 2u;
    uint other_y = (gid.y & 1u) != 0u ? min(site_y + 1u, uv_height - 1u) : site_y;
    DoviChromaSite a = dovi_output_site(uint2(gid.x, site_y), bl_y_tex, bl_uv_tex, el_uv_tex, params, nlq_lut, mmr_table);
    DoviChromaSite b = dovi_output_site(uint2(gid.x, other_y), bl_y_tex, bl_uv_tex, el_uv_tex, params, nlq_lut, mmr_table);
    dovi_write_chroma(out_uv_tex, gid, (a.cb + b.cb + 1) >> 1, (a.cr + b.cr + 1) >> 1, params);
}

// 4:4:4 has the luma's full size: each sample is the mean of the 4:2:0 sites around it (one site on
// a site, two between two, four in a cell's middle), rounded once. Experimental: the reconstruction
// has no 4:4:4 form in the spec, so this only steps the 4:2:0 composition up.
//
// A threadgroup covers a DOVI_444_TILE x DOVI_444_TILE block of output samples. The block's 4:2:0
// sites, plus the one site past it that the odd samples on its far edge average with, are composed
// once into threadgroup memory, then every output sample reads its one to four sites from there. The
// per-sample form composed every site four times for each of the four samples around it, sixteen
// evaluations per site; this does 81 per 256 samples. The sites are the same `dovi_output_site`
// values, clamped to the same edge, and the mean and the write are unchanged, so the output is bit
// for bit what the per-sample form gave. The kernel must be dispatched in threadgroups of exactly
// DOVI_444_TILE x DOVI_444_TILE threads: the block's origin is the threadgroup index.
#define DOVI_444_TILE   16u
#define DOVI_444_SITES  ((DOVI_444_TILE / 2u) + 1u)

[[max_total_threads_per_threadgroup(256)]]
kernel void dovi_compose_chroma_444(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::read>        el_uv_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const float*                    mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]],
    uint2                                  tid           [[thread_position_in_threadgroup]],
    uint2                                  tgid          [[threadgroup_position_in_grid]],
    uint2                                  tg_dim        [[threads_per_threadgroup]])
{
    uint uv_width = (params.bl_width + 1u) / 2u;
    uint uv_height = (params.bl_height + 1u) / 2u;

    threadgroup int tile_cb[DOVI_444_SITES * DOVI_444_SITES];
    threadgroup int tile_cr[DOVI_444_SITES * DOVI_444_SITES];

    // Every thread of the group takes part in filling the tile and reaches the barrier, including
    // threads past the edge of the picture when the grid is rounded up to whole threadgroups.
    uint site_x0 = tgid.x * (DOVI_444_TILE / 2u);
    uint site_y0 = tgid.y * (DOVI_444_TILE / 2u);
    uint lane = tid.y * tg_dim.x + tid.x;
    uint lanes = tg_dim.x * tg_dim.y;
    for (uint i = lane; i < DOVI_444_SITES * DOVI_444_SITES; i += lanes) {
        uint2 site = uint2(min(site_x0 + i % DOVI_444_SITES, uv_width - 1u),
                           min(site_y0 + i / DOVI_444_SITES, uv_height - 1u));
        DoviChromaSite s = dovi_output_site(site, bl_y_tex, bl_uv_tex, el_uv_tex, params, nlq_lut, mmr_table);
        tile_cb[i] = s.cb;
        tile_cr[i] = s.cr;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x >= params.bl_width || gid.y >= params.bl_height) {
        return;
    }

    // Local site (column, row) of the cell this sample is in, and the one it averages with. The tile
    // already holds the far neighbour clamped to the last site, as the per-sample form clamped it.
    uint sx = tid.x / 2u;
    uint sy = tid.y / 2u;
    uint ox = (tid.x & 1u) != 0u ? sx + 1u : sx;
    uint oy = (tid.y & 1u) != 0u ? sy + 1u : sy;
    uint ia = sy * DOVI_444_SITES + sx;
    uint ib = sy * DOVI_444_SITES + ox;
    uint ic = oy * DOVI_444_SITES + sx;
    uint id = oy * DOVI_444_SITES + ox;
    dovi_write_chroma(out_uv_tex, gid,
                      (tile_cb[ia] + tile_cb[ib] + tile_cb[ic] + tile_cb[id] + 2) >> 2,
                      (tile_cr[ia] + tile_cr[ib] + tile_cr[ic] + tile_cr[id] + 2) >> 2, params);
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

    /// The in-place kernels, kept apart from ``kernels`` so a device that cannot bind `read_write` textures
    /// (``DoviFelComposer/supportsInPlaceReadWrite(_:)``) never compiles any text that names them. The luma
    /// kernel binds its 16-bit plane once, as `read_write`; the chroma kernel binds the interleaved plane once,
    /// as 32-bit texels (one Cb and Cr pair each, Cb in the low half, as in the plane's bytes). Both reuse the
    /// pool kernels' bodies; only the chroma accessor is specialised here.
    static let inPlaceKernels = """
// The in-place chroma accessor: a Cb and Cr pair packed in one 32-bit texel.
template <>
struct dovi_uv_plane<texture2d<uint, access::read_write> > {
    static ushort4 load(texture2d<uint, access::read_write> tex, uint2 p)
    {
        uint pair = tex.read(p).r;
        return ushort4(ushort(pair & 0xFFFFu), ushort(pair >> 16), 0, 0);
    }

    static void store(texture2d<uint, access::read_write> tex, ushort4 value, uint2 p)
    {
        tex.write(uint4(uint(value.r) | (uint(value.g) << 16), 0u, 0u, 0u), p);
    }
};

// In place (the base-layer luma plane is the output): one binding, so the kernel reads
// its own sample and writes it back through the same texture.
kernel void dovi_compose_luma_in_place(
    texture2d<ushort, access::read_write>  y_tex         [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::sample>      el_y_tex      [[texture(2)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant float*                        luma_lut      [[buffer(1)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const float*                    mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    dovi_compose_luma_plane(y_tex, bl_uv_tex, el_y_tex, y_tex, params, luma_lut, nlq_lut, mmr_table, gid);
}

// In place (the base-layer chroma plane is the output): one binding for the plane, as 32-bit texels.
kernel void dovi_compose_chroma_in_place(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<uint, access::read_write>    uv_tex        [[texture(1)]],
    texture2d<ushort, access::read>        el_uv_tex     [[texture(2)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const float*                    mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    dovi_compose_chroma_plane(bl_y_tex, uv_tex, el_uv_tex, uv_tex, params, nlq_lut, mmr_table, gid);
}
"""

    /// The source for a device that composes through the output pool only: typedefs, struct block and the pool
    /// and step-up kernels. Contains no `read_write` binding.
    static var poolSource: String {
        #if DEBUG
        // The A/B and measurement variants of the EL readers exist only in the shader a DEBUG build compiles.
        return preamble + "\n#define DOVI_DEBUG_EL_VARIANTS 1\n" + sharedStructs + "\n" + kernels + "\n"
        #else
        return preamble + "\n" + sharedStructs + "\n" + kernels + "\n"
        #endif
    }

    /// Runtime-compiled form for a device that also runs the in-place kernels: ``poolSource`` plus
    /// ``inPlaceKernels``.
    static var source: String {
        poolSource + inPlaceKernels + "\n"
    }

    /// The source `DoviFelComposer` compiles on a device that does (`true`) or does not (`false`) support
    /// the in-place kernels.
    static func source(includingInPlace: Bool) -> String {
        includingInPlace ? source : poolSource
    }
}
#endif
