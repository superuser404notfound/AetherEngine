import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

@Suite("FrameCache")
struct FrameCacheTests {

    /// A 1x1 opaque CGImage to use as a cache payload in tests.
    private func dummyImage() -> CGImage {
        let px: [UInt8] = [0, 0, 0, 255]
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test("Stores and retrieves by bucketed position")
    func storeAndGet() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let img = dummyImage()
        cache.set(img, mode: .thumbnail, seconds: 12.3)
        #expect(cache.get(mode: .thumbnail, seconds: 12.9) === img)
        #expect(cache.get(mode: .thumbnail, seconds: 14.1) == nil)
    }

    @Test("Mode namespaces are independent")
    func modeIsolation() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let img = dummyImage()
        cache.set(img, mode: .thumbnail, seconds: 5.0)
        #expect(cache.get(mode: .snapshot, seconds: 5.0) == nil)
    }

    @Test("Evicts least-recently-used past the per-mode limit")
    func lruEviction() {
        let cache = FrameCache(thumbnailLimit: 2, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let a = dummyImage(), b = dummyImage(), c = dummyImage()
        cache.set(a, mode: .thumbnail, seconds: 1.0)
        cache.set(b, mode: .thumbnail, seconds: 2.0)
        _ = cache.get(mode: .thumbnail, seconds: 1.0)
        cache.set(c, mode: .thumbnail, seconds: 3.0)
        #expect(cache.get(mode: .thumbnail, seconds: 1.0) === a)
        #expect(cache.get(mode: .thumbnail, seconds: 2.0) == nil)
        #expect(cache.get(mode: .thumbnail, seconds: 3.0) === c)
    }

    @Test("Snapshot uses a frame-accurate (sub-second) bucket")
    func snapshotBucket() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 4, thumbnailBucketSeconds: 1.0)
        let a = dummyImage(), b = dummyImage()
        cache.set(a, mode: .snapshot, seconds: 10.10)
        cache.set(b, mode: .snapshot, seconds: 10.90)
        #expect(cache.get(mode: .snapshot, seconds: 10.12) === a)
        #expect(cache.get(mode: .snapshot, seconds: 10.88) === b)
    }

    @Test("clear empties the cache")
    func clear() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        cache.set(dummyImage(), mode: .thumbnail, seconds: 1.0)
        cache.clear()
        #expect(cache.get(mode: .thumbnail, seconds: 1.0) == nil)
    }
}
