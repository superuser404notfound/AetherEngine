//
//  Shaders.metal
//  SteelPlayer
//
//  YUV (NV12) to RGB conversion with BT.709 color matrix.
//  Phase 4 will add HDR→SDR tone mapping (BT.2390-3) here.
//

#include <metal_stdlib>
using namespace metal;

struct QuadVertex {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle — 3 verts covering NDC [-1, +1]²
vertex QuadVertex steel_fullscreen_vertex(uint vid [[vertex_id]]) {
    QuadVertex out;
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0),
    };
    float2 uvs[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0),
    };
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// NV12 YUV→RGB fragment shader (BT.709 video-range).
// Texture 0: Y plane (r8Unorm, full resolution)
// Texture 1: CbCr plane (rg8Unorm, half resolution)
fragment float4 steel_yuv_fragment(
    QuadVertex in [[stage_in]],
    texture2d<float> textureY    [[texture(0)]],
    texture2d<float> textureCbCr [[texture(1)]]
) {
    constexpr sampler texSampler(filter::linear, address::clamp_to_edge);

    float y  = textureY.sample(texSampler, in.uv).r;
    float2 cbcr = textureCbCr.sample(texSampler, in.uv).rg;

    // BT.709 video-range: Y [16/255 .. 235/255], CbCr [16/255 .. 240/255]
    float3 yuv;
    yuv.x = (y - 16.0 / 255.0) * (255.0 / (235.0 - 16.0));   // normalize Y
    yuv.y = cbcr.r - 0.5;                                       // Cb centered
    yuv.z = cbcr.g - 0.5;                                       // Cr centered

    // BT.709 YCbCr→RGB matrix
    float3x3 bt709 = float3x3(
        float3(1.0,     1.0,      1.0),
        float3(0.0,    -0.18732,  1.8556),
        float3(1.5748, -0.46812,  0.0)
    );

    float3 rgb = bt709 * yuv;
    return float4(saturate(rgb), 1.0);
}
