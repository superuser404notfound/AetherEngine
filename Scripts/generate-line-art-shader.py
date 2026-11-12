#!/usr/bin/env python3
"""Generates Sources/AetherEngine/Video/Metal/LineArtShaderSource.swift from Anime4K's
Anime4K_Upscale_CNN_x2_S.glsl and Anime4K_Restore_CNN_S.glsl (https://github.com/bloc97/Anime4K, MIT).

    python3 -I Scripts/generate-line-art-shader.py <Anime4K checkout>/glsl

The generated file is checked in; rerun this only to pick up a new revision of the shader. Each mpv
hook pass becomes one Metal compute kernel: the convolutions run in half precision on rgba16Float
textures at the source size, the depth-to-space pass writes the 2x output and adds the bilinear
source, exactly as the GLSL does.
"""
import os
import re
import sys

OUT = os.path.join(os.path.dirname(__file__), '..', 'Sources', 'AetherEngine', 'Video', 'Metal',
                   'LineArtShaderSource.swift')
REVISION = '7684e9586f8dcc738af08a1cdceb024cc184f426'


def parse(path):
    header, passes, cur = [], [], None
    for line in open(path):
        if line.startswith('//!DESC'):
            cur = {'desc': line[7:].strip(), 'binds': [], 'save': None, 'lines': []}
            passes.append(cur)
        elif cur is None:
            if line.startswith('//'):
                header.append(line[2:].rstrip('\n').strip())
            elif not line.strip() and header and header[-1]:
                header.append('')
        elif line.startswith('//!BIND'):
            cur['binds'].append(line.split()[1])
        elif line.startswith('//!SAVE'):
            cur['save'] = line.split()[1]
        elif not line.startswith('//!'):
            cur['lines'].append(line.rstrip('\n'))
    return header, passes


def conv_kernel(name, p):
    binds = p['binds']
    args = [f"texture2d<half, access::read> {b} [[texture({i})]]" for i, b in enumerate(binds)]
    args.append(f"texture2d<half, access::write> out [[texture({len(binds)})]]")
    args.append("uint2 gid [[thread_position_in_grid]]")
    body = ["    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;",
            "    const int2 g = int2(gid);",
            "    const int2 lim = int2(out.get_width() - 1, out.get_height() - 1);"]
    for b in binds:
        body.append(f"    #define {b}_texOff(o) la_read({b}, g, lim, o)")
        body.append(f"    #define {b}_tex(pos) {b}.read(gid)")
    text = "\n".join(p['lines'])
    text = re.sub(r'vec4 hook\(\)\s*\{', '{', text)
    text = text.replace('mat4(', 'la_m4(').replace('vec4', 'half4').replace('vec2(x_off', 'float2(x_off')
    text = text.replace(', 0.0))', ', 0.0h))')
    text = re.sub(r'return (.*);', r'out.write(\1, gid); return;', text)
    macros = sorted(set(re.findall(r'#define (go_\d+)', text)))
    undef = "".join(f"    #undef {b}_texOff\n    #undef {b}_tex\n" for b in binds) + "".join(f"#undef {m}\n" for m in macros)
    return f"kernel void {name}({', '.join(args)}) {{\n" + "\n".join(body) + "\n" + text + "\n" + undef + "}\n"


def depth_to_space_kernel(name, p):
    last = [b for b in p['binds'] if b != 'MAIN']
    assert len(last) == 1, 'the S network ends in one 4-channel texture'
    return f"""kernel void {name}(texture2d<half, access::sample> MAIN [[texture(0)]],
                      texture2d<half, access::read> {last[0]} [[texture(1)]],
                      texture2d<half, access::write> out [[texture(2)]],
                      uint2 gid [[thread_position_in_grid]]) {{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
    const half c = {last[0]}.read(gid / 2)[(gid.y & 1) * 2 + (gid.x & 1)];
    const float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
    out.write(half4(c) + MAIN.sample(bilinear, uv), gid);
}}
"""


def main():
    header, passes = parse(os.path.join(sys.argv[1], 'Upscale', 'Anime4K_Upscale_CNN_x2_S.glsl'))
    _, restore = parse(os.path.join(sys.argv[1], 'Restore', 'Anime4K_Restore_CNN_S.glsl'))
    assert [p['desc'].split('-')[-1] for p in restore] == ['4x3x3x3', '4x3x3x8', '4x3x3x8', '3x3x3x8'], \
        'unexpected pass layout; this generator is written for Restore_CNN_S'
    assert [p['desc'].split('-')[-1] for p in passes] == ['4x3x3x3', '4x3x3x8', '4x3x3x8', '4x3x3x8', 'Space'], \
        'unexpected pass layout; this generator is written for Upscale_CNN_x2_S'
    kernels = []
    for i, p in enumerate(passes[:-1]):
        kernels.append(conv_kernel(f"lineArtConv{i}", p))
    kernels.append(depth_to_space_kernel("lineArtDepthToSpace", passes[-1]))
    for i, p in enumerate(restore):
        kernels.append(conv_kernel(f"restoreConv{i}", p))
    license_text = "\n".join("/// " + l if l else "///" for l in header)
    metal = """#include <metal_stdlib>
using namespace metal;

static inline half4x4 la_m4(float a, float b, float c, float d, float e, float f, float g, float h,
                            float i, float j, float k, float l, float m, float n, float o, float p) {
    return half4x4(half4(a, b, c, d), half4(e, f, g, h), half4(i, j, k, l), half4(m, n, o, p));
}

static inline half4 la_read(texture2d<half, access::read> t, int2 g, int2 lim, float2 o) {
    return t.read(uint2(clamp(g + int2(o), int2(0), lim)));
}

""" + "\n".join(kernels)
    swift = f"""// Generated by Scripts/generate-line-art-shader.py from Anime4K {REVISION}
// glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl and glsl/Restore/Anime4K_Restore_CNN_S.glsl. Do not edit by hand.

/// The line-art scaler's kernels (AE#1039): Anime4K's Upscale CNN x2 (S) and Restore CNN (S), one compute
/// kernel per mpv hook pass, weights unchanged. The last restore kernel adds its input back, so it writes
/// the restored picture. The original notice:
///
{license_text}
enum LineArtShaderSource {{
    static let convolutionKernels = ["lineArtConv0", "lineArtConv1", "lineArtConv2", "lineArtConv3"]
    static let depthToSpaceKernel = "lineArtDepthToSpace"
    static let restoreKernels = ["restoreConv0", "restoreConv1", "restoreConv2", "restoreConv3"]

    static let source = #\"\"\"
{metal}\"\"\"#
}}
"""
    open(OUT, 'w').write(swift)
    print('wrote', os.path.relpath(OUT))


if __name__ == '__main__':
    main()
