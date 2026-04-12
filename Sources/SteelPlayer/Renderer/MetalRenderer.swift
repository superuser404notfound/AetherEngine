import Foundation
import Metal
import CoreVideo
import QuartzCore

/// Renders CVPixelBuffer frames from the VideoDecoder to a CAMetalLayer
/// via a Metal render pipeline. Handles:
///
/// - CVMetalTextureCache for zero-copy pixel buffer → Metal texture
/// - NV12 (BiPlanar YCbCr) → RGB conversion via BT.709 shader
/// - Aspect-fit viewport calculation (letterbox/pillarbox)
/// - Triple-buffered in-flight semaphore
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

    /// Counter for periodic texture cache flush.
    private var renderCount: Int = 0

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
        guard let fragmentFn = library.makeFunction(name: "steel_yuv_fragment") else {
            throw MetalRendererError.noShaderFunction("steel_yuv_fragment")
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

    /// Render a single decoded NV12 frame to the Metal layer's drawable.
    func render(pixelBuffer: CVPixelBuffer) {
        // Triple-buffer: drop frame if GPU is 3+ frames behind
        if inflightSemaphore.wait(timeout: .now()) == .timedOut {
            #if DEBUG
            if renderCount < 5 { print("[MetalRenderer] Semaphore timeout — dropping frame") }
            #endif
            return
        }

        // Periodic texture cache flush to reclaim stale textures
        renderCount += 1
        #if DEBUG
        if renderCount <= 3 {
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planes = CVPixelBufferGetPlaneCount(pixelBuffer)
            let layerSize = metalLayer.bounds.size
            print("[MetalRenderer] Render #\(renderCount): format=\(fmt), planes=\(planes), layer=\(layerSize)")
        }
        #endif
        if renderCount % 30 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }

        // Create Y plane texture (full resolution, single channel)
        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        var cvTextureY: CVMetalTexture?
        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, yWidth, yHeight, 0, &cvTextureY
        )
        guard status == kCVReturnSuccess,
              let cvY = cvTextureY,
              let textureY = CVMetalTextureGetTexture(cvY) else {
            inflightSemaphore.signal()
            return
        }

        // Create CbCr plane texture (half resolution, two channels)
        let cbcrWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        var cvTextureCbCr: CVMetalTexture?
        status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, cbcrWidth, cbcrHeight, 1, &cvTextureCbCr
        )
        guard status == kCVReturnSuccess,
              let cvCbCr = cvTextureCbCr,
              let textureCbCr = CVMetalTextureGetTexture(cvCbCr) else {
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
            source: CGSize(width: yWidth, height: yHeight),
            drawable: CGSize(width: drawable.texture.width, height: drawable.texture.height)
        )
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(textureY, index: 0)
        encoder.setFragmentTexture(textureCbCr, index: 1)

        // Full-screen triangle: 3 vertices, no vertex buffer
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // CVMetalTexture objects must stay alive until the GPU finishes
        // rendering — their underlying IOSurface gets recycled on release.
        // Capture them explicitly in the completion handler.
        let textures = (cvY, cvCbCr)
        cmdBuffer.addCompletedHandler { [inflightSemaphore, textures] _ in
            withExtendedLifetime(textures) {}
            inflightSemaphore.signal()
        }

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    /// Flush the texture cache (call on seek or when freeing memory).
    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
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
