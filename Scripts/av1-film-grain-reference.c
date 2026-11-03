// Reference digests for `AV1FilmGrainGPUReferenceTests`: dav1d applies AV1 film grain to the synthetic
// 10-bit 4:2:0 picture those tests build, under the same three parameter sets, and prints the FNV-1a 64
// of each output plane. Rerun it when the engine's dav1d moves and paste the digests into the test.
//
// dav1d_apply_grain is public API, but it expects a picture dav1d allocated, and dav1d sets up its
// 10-bit grain functions only once it has decoded a 10-bit frame. So a tiny 10-bit AV1 stream is decoded
// first and its picture is the template, with the synthetic planes and the grain header swapped in. Any
// 10-bit AV1 stream does, for example:
//
//     ffmpeg -f lavfi -i testsrc=s=64x64:r=24:d=0.1 -pix_fmt yuv420p10le -c:v libsvtav1 -f obu tiny.obu
//     clang -O1 $(pkg-config --cflags --libs dav1d) Scripts/av1-film-grain-reference.c -o fgref
//     ./fgref               (reads tiny.obu from the working directory; FGREF_DUMP=1 also writes the luma)
//
// Measured against dav1d 1.5.4, the version the engine's FFmpeg build carries.
#include <dav1d/dav1d.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>



// dav1d's default allocator takes a pool dav1d_open makes for its own copy of the settings; a plain one
// stands in for the picture dav1d_apply_grain allocates.
static int alloc_pic(Dav1dPicture *p, void *cookie) {
    (void)cookie;
    const int aw = (p->p.w + 127) & ~127, ah = (p->p.h + 127) & ~127;
    const ptrdiff_t ys = aw * 2, cs = (aw / 2) * 2;
    uint8_t *buf;
    if (posix_memalign((void **)&buf, 64, ys * ah + 2 * cs * (ah / 2) + 64)) return -1;
    p->stride[0] = ys; p->stride[1] = cs;
    p->data[0] = buf; p->data[1] = buf + ys * ah; p->data[2] = (uint8_t *)p->data[1] + cs * (ah / 2);
    p->allocator_data = buf;
    return 0;
}
static void release_pic(Dav1dPicture *p, void *cookie) { (void)cookie; free(p->allocator_data); }

static const int W = 200, H = 120;
static int Ysample(int x, int y) { return (x * 37 + y * 101 + ((x * y) & 255) * 3) % 1024; }
static int Usample(int x, int y) { return (x * 53 + y * 29 + 300) % 1024; }
static int Vsample(int x, int y) { return (x * 19 + y * 71 + 700) % 1024; }

static uint64_t fnv(uint64_t h, const uint16_t *row, int n) {
    for (int i = 0; i < n; i++) {
        h ^= row[i] & 0xFF; h *= 0x100000001B3ULL;
        h ^= row[i] >> 8;   h *= 0x100000001B3ULL;
    }
    return h;
}

static void run(const char *name, Dav1dContext *c, const Dav1dPicture *tmpl, const Dav1dFilmGrainData *fg) {
    Dav1dSequenceHeader seq = *tmpl->seq_hdr;
    seq.layout = DAV1D_PIXEL_LAYOUT_I420; seq.hbd = 1; seq.mtrx = DAV1D_MC_BT2020_NCL;
    Dav1dFrameHeader frm = *tmpl->frame_hdr;
    frm.film_grain.present = 1; frm.film_grain.update = 1; frm.film_grain.data = *fg;
    frm.width[0] = frm.width[1] = W; frm.height = H;

    const int cw = (W + 1) / 2, ch = (H + 1) / 2;
    // dav1d's grain reads the input with the output's strides (in decoding the two are always alike), so
    // the input takes the strides alloc_pic gives the output.
    const int aw = (W + 127) & ~127;
    const ptrdiff_t ys = aw * 2, cs = (aw / 2) * 2;
    uint16_t *yp, *up, *vp;
    posix_memalign((void **)&yp, 64, ys * H); posix_memalign((void **)&up, 64, cs * ch); posix_memalign((void **)&vp, 64, cs * ch);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) yp[y * ys / 2 + x] = Ysample(x, y);
    for (int y = 0; y < ch; y++) for (int x = 0; x < cw; x++) { up[y * cs / 2 + x] = Usample(x, y); vp[y * cs / 2 + x] = Vsample(x, y); }

    Dav1dPicture in = *tmpl;
    in.seq_hdr = &seq; in.frame_hdr = &frm; in.data[0] = yp; in.data[1] = up; in.data[2] = vp;
    in.stride[0] = ys; in.stride[1] = cs; in.p.w = W; in.p.h = H; in.p.layout = DAV1D_PIXEL_LAYOUT_I420; in.p.bpc = 10;

    Dav1dPicture out; memset(&out, 0, sizeof out);
    int res = dav1d_apply_grain(c, &out, &in);
    if (res < 0) { fprintf(stderr, "%s: dav1d_apply_grain %d\n", name, res); exit(1); }
    uint64_t hy = 0xCBF29CE484222325ULL, hu = hy, hv = hy;
    for (int y = 0; y < H; y++) hy = fnv(hy, (uint16_t *)((uint8_t *)out.data[0] + y * out.stride[0]), W);
    for (int y = 0; y < ch; y++) {
        hu = fnv(hu, (uint16_t *)((uint8_t *)out.data[1] + y * out.stride[1]), cw);
        hv = fnv(hv, (uint16_t *)((uint8_t *)out.data[2] + y * out.stride[1]), cw);
    }
    if (getenv("FGREF_DUMP")) {
        char path[64]; snprintf(path, sizeof path, "ref_%s_y.raw", name); FILE *o = fopen(path, "wb");
        for (int y = 0; y < H; y++) fwrite((uint8_t *)out.data[0] + y * out.stride[0], 2, W, o);
        fclose(o);
    }
    printf("%s Y=0x%016llX U=0x%016llX V=0x%016llX\n", name, (unsigned long long)hy, (unsigned long long)hu, (unsigned long long)hv);
}

int main(void) {
    printf("dav1d %s\n", dav1d_version());
    Dav1dSettings s; dav1d_default_settings(&s); s.n_threads = 1; s.max_frame_delay = 1;
    s.allocator.alloc_picture_callback = alloc_pic; s.allocator.release_picture_callback = release_pic; s.allocator.cookie = NULL;
    Dav1dContext *c; if (dav1d_open(&c, &s) < 0) return 1;
    FILE *f = fopen("tiny.obu", "rb"); if (!f) return 2;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    Dav1dData data; uint8_t *bytes = dav1d_data_create(&data, n); fread(bytes, 1, n, f); fclose(f);
    Dav1dPicture tmpl; memset(&tmpl, 0, sizeof tmpl);
    int got = -1;
    while (data.sz > 0) { if (dav1d_send_data(c, &data) < 0) break; if ((got = dav1d_get_picture(c, &tmpl)) == 0) break; }
    while (got != 0 && (got = dav1d_get_picture(c, &tmpl)) == DAV1D_ERR(EAGAIN)) {}
    if (got != 0 || tmpl.p.bpc != 10) { fprintf(stderr, "template decode failed (%d, bpc %d)\n", got, tmpl.p.bpc); return 3; }

    // A: separate luma and chroma points, lag 3, overlap, clipped to the restricted range.
    Dav1dFilmGrainData a; memset(&a, 0, sizeof a);
    a.seed = 0x1234; a.num_y_points = 4;
    int ay[4][2] = {{0, 20}, {64, 40}, {128, 60}, {255, 30}};
    for (int i = 0; i < 4; i++) { a.y_points[i][0] = ay[i][0]; a.y_points[i][1] = ay[i][1]; }
    a.num_uv_points[0] = 2; a.uv_points[0][0][0] = 0; a.uv_points[0][0][1] = 30; a.uv_points[0][1][0] = 255; a.uv_points[0][1][1] = 50;
    a.num_uv_points[1] = 3; a.uv_points[1][0][0] = 16; a.uv_points[1][0][1] = 10; a.uv_points[1][1][0] = 128; a.uv_points[1][1][1] = 45; a.uv_points[1][2][0] = 240; a.uv_points[1][2][1] = 20;
    a.scaling_shift = 10; a.ar_coeff_lag = 3; a.ar_coeff_shift = 7; a.grain_scale_shift = 0;
    for (int i = 0; i < 24; i++) a.ar_coeffs_y[i] = (int8_t)(((i * 29) % 41) - 20);
    for (int i = 0; i < 25; i++) { a.ar_coeffs_uv[0][i] = (int8_t)(((i * 17) % 37) - 18); a.ar_coeffs_uv[1][i] = (int8_t)(((i * 23) % 31) - 15); }
    a.uv_mult[0] = -40; a.uv_mult[1] = 25; a.uv_luma_mult[0] = 60; a.uv_luma_mult[1] = -30; a.uv_offset[0] = 20; a.uv_offset[1] = -35;
    a.overlap_flag = 1; a.clip_to_restricted_range = 1;
    run("A", c, &tmpl, &a);

    // B: chroma scaled from luma, lag 0, no overlap, full range, grain scale shift 1.
    Dav1dFilmGrainData b; memset(&b, 0, sizeof b);
    b.seed = 0xBEEF; b.num_y_points = 2; b.y_points[0][0] = 0; b.y_points[0][1] = 64; b.y_points[1][0] = 255; b.y_points[1][1] = 96;
    b.chroma_scaling_from_luma = 1; b.scaling_shift = 9; b.ar_coeff_lag = 0; b.ar_coeff_shift = 6; b.grain_scale_shift = 1;
    b.ar_coeffs_uv[0][0] = 30; b.ar_coeffs_uv[1][0] = -22;
    b.uv_mult[0] = 0; b.uv_mult[1] = 0; b.uv_luma_mult[0] = 64; b.uv_luma_mult[1] = 64; b.uv_offset[0] = 0; b.uv_offset[1] = 0;
    b.overlap_flag = 0; b.clip_to_restricted_range = 0;
    run("B", c, &tmpl, &b);

    // C: luma grain only, lag 1, overlap; chroma passes through.
    Dav1dFilmGrainData d; memset(&d, 0, sizeof d);
    d.seed = 0x7; d.num_y_points = 3; d.y_points[0][0] = 32; d.y_points[0][1] = 80; d.y_points[1][0] = 160; d.y_points[1][1] = 50; d.y_points[2][0] = 224; d.y_points[2][1] = 100;
    d.scaling_shift = 11; d.ar_coeff_lag = 1; d.ar_coeff_shift = 8;
    for (int i = 0; i < 4; i++) d.ar_coeffs_y[i] = (int8_t)(10 - i * 7);
    d.overlap_flag = 1; d.clip_to_restricted_range = 0;
    run("C", c, &tmpl, &d);
    return 0;
}
