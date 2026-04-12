import Foundation
import Metal
import CoreVideo
import QuartzCore

/// Renders CVPixelBuffer frames from the VideoDecoder to a CAMetalLayer
/// via a Metal render pipeline. Handles:
///
/// - CVMetalTextureCache for zero-copy pixel buffer → Metal texture
/// - Full-screen triangle vertex + passthrough fragment shader
/// - Aspect-fit viewport calculation (letterbox/pillarbox)
/// - Triple-buffered in-flight semaphore
///
/// The actual tone mapping (HDR → SDR) will be added in Phase 4. For
/// Phase 1, we render the decoded frame as-is (which is already in the
/// native pixel format VideoToolbox outputs — typically NV12 YCbCr or
/// BGRA depending on settings).
final class MetalRenderer {

    // MARK: - Output

    /// The Metal layer this renderer draws into.
    let metalLayer: CAMetalLayer

    // MARK: - Pipeline

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    /// Triple-buffer guard so the GPU doesn't fall unboundedly behind.
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    // MARK: - Init

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRendererError.noDevice
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw MetalRendererError.noCommandQueue
        }
        self.commandQueue = queue

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        self.metalLayer = layer

        // Load shaders from the package bundle
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw MetalRendererError.noLibrary
        }
        guard let vertexFn = library.makeFunction(name: "steel_fullscreen_vertex") else {
            throw MetalRendererError.noShaderFunction("steel_fullscreen_vertex")
        }
        guard let fragmentFn = library.makeFunction(name: "steel_passthrough_fragment") else {
            throw MetalRendererError.noShaderFunction("steel_passthrough_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat

        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else {
            throw MetalRendererError.noTextureCache
        }
        self.textureCache = textureCache

        #if DEBUG
        print("[MetalRenderer] Initialized (device=\(device.name))")
        #endif
    }

    // MARK: - Render

    /// Render a single decoded frame to the Metal layer's drawable.
    /// Call this from the display link callback with the latest frame.
    func render(pixelBuffer: CVPixelBuffer) {
        // Triple-buffer: drop frame if GPU is 3+ frames behind
        if inflightSemaphore.wait(timeout: .now()) == .timedOut {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Wrap the decoded BGRA pixel buffer as a Metal texture
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cv = cvTexture,
              let sourceTexture = CVMetalTextureGetTexture(cv) else {
            inflightSemaphore.signal()
            return
        }

        guard let drawable = metalLayer.nextDrawable() else {
            inflightSemaphore.signal()
            return
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            inflightSemaphore.signal()
            return
        }

        encoder.setRenderPipelineState(pipelineState)

        let viewport = Self.aspectFitViewport(
            source: CGSize(width: width, height: height),
            drawable: CGSize(width: drawable.texture.width, height: drawable.texture.height)
        )
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(sourceTexture, index: 0)

        // Full-screen triangle: 3 vertices, no vertex buffer
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // Hold CVMetalTexture until GPU is done with it
        cmdBuffer.addCompletedHandler { [inflightSemaphore] _ in
            _ = cv
            inflightSemaphore.signal()
        }

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - Viewport

    static func aspectFitViewport(source: CGSize, drawable: CGSize) -> MTLViewport {
        guard source.width > 0, source.height > 0, drawable.width > 0, drawable.height > 0 else {
            return MTLViewport(originX: 0, originY: 0, width: drawable.width, height: drawable.height, znear: 0, zfar: 1)
        }
        let srcAspect = source.width / source.height
        let dstAspect = drawable.width / drawable.height

        var w = drawable.width
        var h = drawable.height
        if srcAspect > dstAspect {
            h = drawable.width / srcAspect
        } else {
            w = drawable.height * srcAspect
        }
        let x = (drawable.width - w) / 2.0
        let y = (drawable.height - h) / 2.0
        return MTLViewport(originX: x, originY: y, width: w, height: h, znear: 0, zfar: 1)
    }
}

enum MetalRendererError: Error {
    case noDevice
    case noCommandQueue
    case noLibrary
    case noShaderFunction(String)
    case noTextureCache
}
