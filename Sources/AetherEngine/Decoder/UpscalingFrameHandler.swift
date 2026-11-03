import Foundation
import CoreMedia
import CoreVideo

/// Runs the upscale stage (#846) on every frame handed to a decoder's frame handler; a nil from the
/// stage delivers the original frame. The stage gets each frame's PTS to time its budget.
enum UpscalingFrameHandler {
    static func wrap(
        _ handler: @escaping DecodedFrameHandler,
        upscale: @escaping @Sendable (CVPixelBuffer, CMTime) -> CVPixelBuffer?
    ) -> DecodedFrameHandler {
        { buffer, pts, hdr10Plus in
            handler(upscale(buffer, pts) ?? buffer, pts, hdr10Plus)
        }
    }
}
