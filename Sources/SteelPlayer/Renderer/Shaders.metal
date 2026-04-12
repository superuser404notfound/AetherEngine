//
//  Shaders.metal
//  SteelPlayer
//
//  Phase 1: Simple passthrough vertex + fragment pair.
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

// Passthrough fragment — just samples the decoded frame texture.
// Phase 4 will add tone mapping + color space conversion here.
fragment float4 steel_passthrough_fragment(
    QuadVertex in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]]
) {
    constexpr sampler texSampler(filter::linear, address::clamp_to_edge);
    return sourceTexture.sample(texSampler, in.uv);
}
