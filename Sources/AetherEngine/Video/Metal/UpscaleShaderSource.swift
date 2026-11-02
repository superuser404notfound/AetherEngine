import Foundation
import CoreVideo

/// The Y'CbCr matrix the conversion runs with, from the buffer's tag. Untagged and unrecognised (SMPTE 240M
/// included) decode as BT.709; the output buffer keeps the input's tag either way.
enum UpscaleMatrix: Equatable, Sendable {
    case bt601, bt709, bt2020

    var kr: Float {
        switch self { case .bt601: 0.299; case .bt709: 0.2126; case .bt2020: 0.2627 }
    }
    var kb: Float {
        switch self { case .bt601: 0.114; case .bt709: 0.0722; case .bt2020: 0.0593 }
    }

    static func of(_ buffer: CVPixelBuffer) -> UpscaleMatrix {
        guard let tag = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else { return .bt709 }
        if tag == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return .bt601 }
        if tag == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return .bt2020 }
        return .bt709
    }
}

/// Layout matches `UpscaleColorParams` in the shader.
struct UpscaleColorParams {
    var videoRange: UInt32
    var kr: Float
    var kb: Float

    init(videoRange: Bool, matrix: UpscaleMatrix) {
        self.videoRange = videoRange ? 1 : 0
        kr = matrix.kr
        kb = matrix.kb
    }
}

/// NV12 <-> RGBA kernels around MetalFX Spatial, which takes and returns RGBA. SDR only, so no transfer or
/// primaries handling: the conversion is the plain matrix (from Kr and Kb) on the coded (gamma) values.
enum UpscaleShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct UpscaleColorParams { uint videoRange; float kr; float kb; };

    inline float3 decodeYCbCr(float y, float2 c, bool videoRange, float kr, float kb) {
        float3 v;
        if (videoRange) {
            v = float3((y * 255.0 - 16.0) / 219.0, (c * 255.0 - 128.0) / 224.0);
        } else {
            v = float3(y, c - 128.0 / 255.0);
        }
        float kg = 1.0 - kr - kb;
        float r = v.x + 2.0 * (1.0 - kr) * v.z;
        float b = v.x + 2.0 * (1.0 - kb) * v.y;
        float g = (v.x - kr * r - kb * b) / kg;
        return float3(r, g, b);
    }

    inline float3 encodeYCbCr(float3 rgb, bool videoRange, float kr, float kb) {
        float y = dot(rgb, float3(kr, 1.0 - kr - kb, kb));
        float cb = (rgb.b - y) / (2.0 * (1.0 - kb));
        float cr = (rgb.r - y) / (2.0 * (1.0 - kr));
        if (videoRange) {
            return float3((16.0 + 219.0 * y) / 255.0, (128.0 + 224.0 * cb) / 255.0, (128.0 + 224.0 * cr) / 255.0);
        }
        return float3(y, cb + 128.0 / 255.0, cr + 128.0 / 255.0);
    }

    kernel void nv12ToRGBA(constant UpscaleColorParams &p [[buffer(0)]],
                           texture2d<float, access::read> yTex [[texture(0)]],
                           texture2d<float, access::read> cTex [[texture(1)]],
                           texture2d<float, access::write> outTex [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
        float y = yTex.read(gid).r;
        float2 c = cTex.read(gid / 2).rg;
        float3 rgb = saturate(decodeYCbCr(y, c, p.videoRange == 1, p.kr, p.kb));
        outTex.write(float4(rgb, 1.0), gid);
    }

    // One thread per 2x2 luma block: writes its four Y samples and one CbCr from the averaged RGB.
    kernel void rgbaToNV12(constant UpscaleColorParams &p [[buffer(0)]],
                           texture2d<float, access::read> inTex [[texture(0)]],
                           texture2d<float, access::write> yTex [[texture(1)]],
                           texture2d<float, access::write> cTex [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 base = gid * 2;
        if (base.x >= inTex.get_width() || base.y >= inTex.get_height()) { return; }
        bool videoRange = p.videoRange == 1;
        float3 sum = float3(0.0);
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 pos = base + uint2(dx, dy);
                float3 rgb = inTex.read(pos).rgb;
                sum += rgb;
                yTex.write(float4(encodeYCbCr(rgb, videoRange, p.kr, p.kb).x, 0.0, 0.0, 1.0), pos);
            }
        }
        float3 e = encodeYCbCr(sum * 0.25, videoRange, p.kr, p.kb);
        cTex.write(float4(e.y, e.z, 0.0, 1.0), gid);
    }
    """
}
