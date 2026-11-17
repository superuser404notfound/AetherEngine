import CoreVideo
import Foundation
import Metal

/// The Metal plumbing the GPU frame stages share (audit GPU-R201): plane textures from one texture cache,
/// a compute dispatch that also works on GPUs without non-uniform threadgroups, and the lease that keeps
/// one frame's textures and their cache alive until its command buffer is done. `FrameChain`, the
/// upscaler's MetalFX path, the FEL composer and `GPUFrameConverter` all go through it.
final class MetalFrameIO: @unchecked Sendable {
    let device: MTLDevice
    let textureCache: CVMetalTextureCache
    /// `dispatchThreads` needs non-uniform threadgroups: `MTLGPUFamily.apple4` (A11) and later, or a Mac
    /// GPU. The Apple TV 4K 1st gen (A10X) runs tvOS 26 without them (audit GPU-204).
    let supportsNonUniformThreadgroups: Bool

    /// nil when CoreVideo makes no texture cache. `nonUniformThreadgroups` overrides the device's answer.
    init?(device: MTLDevice, nonUniformThreadgroups: Bool? = nil) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        textureCache = cache
        supportsNonUniformThreadgroups = nonUniformThreadgroups ?? Self.supportsNonUniformThreadgroups(device)
    }

    deinit { CVMetalTextureCacheFlush(textureCache, 0) }

    static func supportsNonUniformThreadgroups(_ device: MTLDevice) -> Bool {
        device.supportsFamily(.apple4) || device.supportsFamily(.mac2)
    }

    /// An empty lease on this cache, for one frame's textures.
    func lease() -> MetalTextureLease { MetalTextureLease(cache: textureCache) }

    /// Plane `plane` of `buffer` as a `format` texture of `width` x `height` (the plane's size when nil),
    /// held by `lease`. nil when CoreVideo refuses it.
    func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int? = nil, height: Int? = nil,
                 in lease: MetalTextureLease) -> MTLTexture? {
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, format,
                width ?? CVPixelBufferGetWidthOfPlane(buffer, plane), height ?? CVPixelBufferGetHeightOfPlane(buffer, plane),
                plane, &ref) == kCVReturnSuccess,
              let ref, let texture = CVMetalTextureGetTexture(ref)
        else { return nil }
        lease.hold(ref)
        return texture
    }

    /// Lets go of cached textures nothing holds any more. On the encoding thread: a texture an earlier
    /// frame still uses stays alive in that frame's lease.
    func flush() { CVMetalTextureCacheFlush(textureCache, 0) }

    func dispatch(_ encoder: MTLComputeCommandEncoder, grid: (width: Int, height: Int), threadgroup: MTLSize) {
        Self.dispatch(encoder, grid: grid, threadgroup: threadgroup, nonUniform: supportsNonUniformThreadgroups)
    }

    /// Covers exactly `grid` threads. With non-uniform threadgroups `dispatchThreads` splits the edge
    /// groups itself; without them whole groups are dispatched (`threadgroupCount`), the extra threads at
    /// the right and bottom edge are real, and each kernel's bounds guard discards them.
    static func dispatch(_ encoder: MTLComputeCommandEncoder, grid: (width: Int, height: Int), threadgroup: MTLSize,
                         nonUniform: Bool) {
        guard grid.width > 0, grid.height > 0 else { return }
        if nonUniform {
            encoder.dispatchThreads(MTLSize(width: grid.width, height: grid.height, depth: 1),
                                    threadsPerThreadgroup: threadgroup)
        } else {
            encoder.dispatchThreadgroups(threadgroupCount(grid: grid, threadgroup: threadgroup),
                                         threadsPerThreadgroup: threadgroup)
        }
    }

    /// The whole threadgroups that cover `grid`.
    static func threadgroupCount(grid: (width: Int, height: Int), threadgroup: MTLSize) -> MTLSize {
        MTLSize(width: (grid.width + threadgroup.width - 1) / threadgroup.width,
                height: (grid.height + threadgroup.height - 1) / threadgroup.height, depth: 1)
    }
}

/// One frame's CoreVideo objects (its plane textures, and any buffer that has to live as long), with the
/// texture cache the textures came from. A `CVMetalTexture` calls back into its cache when it finalizes
/// and does not retain it, so the cache has to outlive the textures: without that the FEL composer crashed
/// in `CVMetalTextureCache::bufferBackingNotInUse` when it was released with a command buffer in flight,
/// and the tone mapper drops its chain (and the chain's cache) with two frames on the GPU (audit GPU-201).
/// The lease holds the cache and lets the textures go first.
final class MetalTextureLease: @unchecked Sendable {
    let cache: CVMetalTextureCache
    private var held: [CVBuffer] = []

    init(cache: CVMetalTextureCache) {
        self.cache = cache
    }

    /// Filled on the encoding thread before the work is committed, released after it completed.
    func hold(_ object: CVBuffer) { held.append(object) }

    var count: Int { held.count }

    deinit {
        // Explicit, so the order is a statement: the textures go here, the cache after this body.
        held.removeAll()
    }
}

/// Compiled pipelines per Metal device, kept for the process (audit GPU-R202). Callers that arrive while
/// the first build runs wait for it instead of compiling twice.
///
/// A failed build is kept too, so later callers fail at once instead of compiling the libraries again on
/// every stage build, but only for `failureRetryInterval` (review R-P4-1). Metal reports a compiler-service
/// interruption under memory pressure (`XPC_ERROR_CONNECTION_INTERRUPTED`) with the same
/// `MTLLibraryError.compileFailure` a broken shader gets, so the two cannot be told apart, and a failure
/// kept for good switched tone mapping and upscaling off until the app relaunched. 60 s by default: a
/// failure that is real then costs one compile a minute however often stages are rebuilt, and one that
/// was not is gone by the next title or rebuild. nil keeps a failure for the process, for a caller that
/// asks on every frame (the FEL composer), where a retry would put a compile on the decode thread.
final class MetalPipelineCache<Value>: @unchecked Sendable {
    private struct Entry {
        let result: Result<Value, Error>
        let builtAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private let failureRetryInterval: Duration?
    private let now: @Sendable () -> ContinuousClock.Instant

    init(failureRetryInterval: Duration? = .seconds(60),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.failureRetryInterval = failureRetryInterval
        self.now = now
    }

    func resolve(device: MTLDevice, compile: () throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        let key = device.registryID
        if let entry = entries[key], !isExpired(entry) { return try entry.result.get() }
        let result = Result { try compile() }
        entries[key] = Entry(result: result, builtAt: now())
        return try result.get()
    }

    private func isExpired(_ entry: Entry) -> Bool {
        guard case .failure = entry.result, let failureRetryInterval else { return false }
        return entry.builtAt.duration(to: now()) >= failureRetryInterval
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
