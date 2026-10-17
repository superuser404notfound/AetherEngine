// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import AetherLibavformat
@_spi(Diagnostics) @testable import AetherEngine

/// A seek on the Profile 7 FEL route has to flush and realign both layers on the same picture
/// (the maintainer's parity requirement). The AV1/VP9 software path has one decoder to flush; here
/// there are two VideoToolbox sessions, the composer, the ordered delivery, the two frame queues and
/// the side-data ring, and a seek lands on timestamps the pre-seek frames may already have used (a
/// backward seek replays the same PTS keys). These tests drive the frame handlers with tagged
/// synthetic buffers and check what the composer was asked to pair and what reached `onFrame`.
@Suite(.serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)))
struct DualLayerSeekRealignmentTests {

    // MARK: - Fixtures

    private static let frameTicks: Int64 = 3754
    private static func pts(_ frame: Int64) -> CMTime { CMTime(value: frame * frameTicks, timescale: 90000) }

    private static func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        return status == kCVReturnSuccess ? out : nil
    }

    private static func params() -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = 64; p.blHeight = 64; p.elWidth = 32; p.elHeight = 32
        return p
    }

    private struct Pair { let base: CVPixelBuffer; let enhancement: CVPixelBuffer }

    /// Records every pairing the decoder asks for and counts flushes. Completes at once with the
    /// base buffer, unless `holdFirst` is set: then the first composition's completion is parked
    /// until `releaseHeld()`, the way a command buffer still on the GPU holds it.
    private final class FakeComposer: FelComposing, @unchecked Sendable {
        private let lock = NSLock()
        private var _pairs: [Pair] = []
        private var _flushes = 0
        private var held: (@Sendable (CVPixelBuffer?) -> Void)?
        private var heldBase: CVPixelBuffer?
        private let holdFirst: Bool

        init(holdFirst: Bool = false) { self.holdFirst = holdFirst }

        var pairs: [Pair] { lock.lock(); defer { lock.unlock() }; return _pairs }
        var flushCount: Int { lock.lock(); defer { lock.unlock() }; return _flushes }

        func acquireSlot() {}
        func releaseSlot() {}
        func flush() { lock.lock(); _flushes += 1; lock.unlock() }
        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            composeAsyncWithAcquiredSlot(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer,
                                         params: params, frameIndex: frameIndex, completion: completion)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer,
                                          params: DoviMetalParams, frameIndex: UInt32,
                                          completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            lock.lock()
            let first = _pairs.isEmpty
            _pairs.append(Pair(base: baseBuffer, enhancement: enhancementBuffer))
            if holdFirst, first {
                held = completion
                heldBase = baseBuffer
                lock.unlock()
                return
            }
            lock.unlock()
            completion(baseBuffer)
        }

        func releaseHeld() {
            lock.lock()
            let completion = held, base = heldBase
            held = nil; heldBase = nil
            lock.unlock()
            completion?(base)
        }
    }

    /// A VideoToolbox session stand-in that only counts what the decoder does to it.
    private final class FakeSession: SingleLayerVideoDecoder, @unchecked Sendable {
        private let lock = NSLock()
        private var _flushes = 0
        var flushCount: Int { lock.lock(); defer { lock.unlock() }; return _flushes }
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        var feedEpoch: UInt64 = 0
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {}
        func open(parameterSets: [[UInt8]], timeBase: AVRational,
                  onFrame: @escaping DecodedFrameHandler) throws {}
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {}
        func flush() { lock.lock(); _flushes += 1; lock.unlock() }
        func close() {}
    }

    private final class Deliveries: @unchecked Sendable {
        struct Frame { let buffer: CVPixelBuffer; let pts: CMTime; let afterMarker: Bool }
        private let lock = NSLock()
        private var frames: [Frame] = []
        private var marker = false
        func record(_ buffer: CVPixelBuffer, _ pts: CMTime) {
            lock.lock(); frames.append(Frame(buffer: buffer, pts: pts, afterMarker: marker)); lock.unlock()
        }
        func setMarker() { lock.lock(); marker = true; lock.unlock() }
        var afterMarker: [Frame] { lock.lock(); defer { lock.unlock() }; return frames.filter(\.afterMarker) }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    private struct Rig {
        let decoder: DualLayerVideoDecoder
        let composer: FakeComposer
        let primary: FakeSession
        let enhancement: FakeSession
        let deliveries: Deliveries
    }

    private static func rig(holdFirst: Bool = false) -> Rig {
        let composer = FakeComposer(holdFirst: holdFirst)
        let primary = FakeSession(), enhancement = FakeSession()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer, primaryDecoder: primary,
                                            enhancementDecoder: enhancement)
        decoder.onFrame = { buffer, pts, _ in deliveries.record(buffer, pts) }
        decoder.primeForTesting(enhancementLayer: true)
        return Rig(decoder: decoder, composer: composer, primary: primary, enhancement: enhancement,
                   deliveries: deliveries)
    }

    // MARK: - Tests

    @Test("a seek flushes both VideoToolbox sessions and the composer, and empties the pairing state")
    func flushReachesEveryStage() throws {
        let r = Self.rig()
        defer { r.decoder.close() }

        // Two complete pairs, a lone EL and a lone BL: every queue and the side-data ring hold something.
        for i in 0..<4 {
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
        }
        for i in 0..<2 {
            let bl = try #require(Self.buffer(width: 64, height: 64))
            let el = try #require(Self.buffer(width: 32, height: 32))
            r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        r.decoder.handleEnhancementLayerFrame(elBuffer: try #require(Self.buffer(width: 32, height: 32)), pts: Self.pts(2))
        r.decoder.handleBaseLayerFrame(baseBuffer: try #require(Self.buffer(width: 64, height: 64)),
                                       pts: Self.pts(3), hdr10Data: nil)
        let before = r.decoder.stateSnapshotForTesting
        #expect(before.rpuCacheCount > 0)
        #expect(before.elQueueCount + before.blQueueCount > 0)

        let epoch = r.decoder.feedEpoch
        r.decoder.flush()

        #expect(r.primary.flushCount == 1)
        #expect(r.enhancement.flushCount == 1)
        #expect(r.composer.flushCount == 1)
        #expect(r.decoder.feedEpoch == epoch + 1)
        let after = r.decoder.stateSnapshotForTesting
        #expect(after.blQueueCount == 0 && after.elQueueCount == 0)
        #expect(after.rpuCacheCount == 0 && after.dmRpuCacheCount == 0)
        #expect(!after.draining)
    }

    @Test("an enhancement layer from before a seek is never composed onto a post-seek base layer")
    func staleEnhancementLayerIsNotPaired() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }

        // The pre-seek EL for frame 10 is decoded, its base layer never is: the seek retires it.
        let staleEL = try #require(Self.buffer(width: 32, height: 32))
        r.decoder.handleEnhancementLayerFrame(elBuffer: staleEL, pts: Self.pts(10))
        r.decoder.flush()
        r.deliveries.setMarker()

        // A backward seek replays the same timestamps. The base layer comes first this time.
        let postBL = try #require(Self.buffer(width: 64, height: 64))
        let postEL = try #require(Self.buffer(width: 32, height: 32))
        r.decoder.seedRPUForTesting(pts: Self.pts(10), params: Self.params(), displayMetadataNAL: nil)
        r.decoder.handleBaseLayerFrame(baseBuffer: postBL, pts: Self.pts(10), hdr10Data: nil)
        r.decoder.quiesceForTesting()
        #expect(r.composer.pairs.isEmpty, "the post-seek base layer was composed with a pre-seek enhancement layer")

        r.decoder.handleEnhancementLayerFrame(elBuffer: postEL, pts: Self.pts(10))
        try await waitFor { r.deliveries.afterMarker.count == 1 }
        let pairs = r.composer.pairs
        #expect(pairs.count == 1)
        #expect(pairs.first?.base === postBL)
        #expect(pairs.first?.enhancement === postEL)
        #expect(pairs.allSatisfy { $0.enhancement !== staleEL })
    }

    @Test("a base layer waiting for its enhancement layer when the seek lands is dropped, not delivered late")
    func staleBaseLayerIsNotDelivered() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }

        let staleBL = try #require(Self.buffer(width: 64, height: 64))
        r.decoder.seedRPUForTesting(pts: Self.pts(5), params: Self.params(), displayMetadataNAL: nil)
        r.decoder.handleBaseLayerFrame(baseBuffer: staleBL, pts: Self.pts(5), hdr10Data: nil)
        r.decoder.flush()
        r.deliveries.setMarker()

        // The post-seek EL for the same key must not find the pre-seek base layer.
        let postEL = try #require(Self.buffer(width: 32, height: 32))
        r.decoder.handleEnhancementLayerFrame(elBuffer: postEL, pts: Self.pts(5))
        r.decoder.quiesceForTesting()
        #expect(r.composer.pairs.isEmpty)
        #expect(r.deliveries.afterMarker.isEmpty)

        let postBL = try #require(Self.buffer(width: 64, height: 64))
        r.decoder.seedRPUForTesting(pts: Self.pts(5), params: Self.params(), displayMetadataNAL: nil)
        r.decoder.handleBaseLayerFrame(baseBuffer: postBL, pts: Self.pts(5), hdr10Data: nil)
        try await waitFor { r.deliveries.afterMarker.count == 1 }
        #expect(r.deliveries.afterMarker.first?.buffer === postBL)
        #expect(r.composer.pairs.first?.base === postBL)
        #expect(r.composer.pairs.first?.enhancement === postEL)
    }

    @Test("after a seek every frame is composed with its own layer's picture, in either arrival order")
    func postSeekFramesPairByPicture() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }

        // Pre-seek leftovers on keys the replay is about to reuse.
        for i in 10..<13 {
            r.decoder.handleEnhancementLayerFrame(elBuffer: try #require(Self.buffer(width: 32, height: 32)), pts: Self.pts(Int64(i)))
        }
        r.decoder.handleBaseLayerFrame(baseBuffer: try #require(Self.buffer(width: 64, height: 64)), pts: Self.pts(13), hdr10Data: nil)
        r.decoder.flush()
        r.deliveries.setMarker()

        var bases: [CVPixelBuffer] = [], enhancements: [CVPixelBuffer] = []
        for i in 0..<6 {
            let bl = try #require(Self.buffer(width: 64, height: 64))
            let el = try #require(Self.buffer(width: 32, height: 32))
            bases.append(bl); enhancements.append(el)
            let key = Int64(10 + i)
            r.decoder.seedRPUForTesting(pts: Self.pts(key), params: Self.params(), displayMetadataNAL: nil)
            if i % 2 == 0 {
                r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(key), hdr10Data: nil)
                r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(key))
            } else {
                r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(key))
                r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(key), hdr10Data: nil)
            }
        }
        try await waitFor { r.deliveries.afterMarker.count == 6 }
        let delivered = r.deliveries.afterMarker
        #expect(zip(delivered, delivered.dropFirst()).allSatisfy { CMTimeCompare($0.pts, $1.pts) < 0 })
        #expect(zip(delivered, bases).allSatisfy { $0.buffer === $1 })
        let pairs = r.composer.pairs
        #expect(pairs.count == 6)
        for pair in pairs {
            let i = bases.firstIndex { $0 === pair.base }
            #expect(i != nil && pair.enhancement === enhancements[i!], "base and enhancement are not the same picture")
        }
    }

    @Test("a seek during an in-flight composition drops that frame, and the first post-seek frame is the paired one")
    func seekDuringInFlightCompose() async throws {
        let r = Self.rig(holdFirst: true)
        defer { r.decoder.close() }

        let staleBL = try #require(Self.buffer(width: 64, height: 64))
        let staleEL = try #require(Self.buffer(width: 32, height: 32))
        r.decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        r.decoder.handleEnhancementLayerFrame(elBuffer: staleEL, pts: Self.pts(1))
        r.decoder.handleBaseLayerFrame(baseBuffer: staleBL, pts: Self.pts(1), hdr10Data: nil)
        #expect(r.composer.pairs.count == 1, "the first composition must be on the GPU")

        // The seek lands while it is there.
        r.decoder.flush()
        r.deliveries.setMarker()

        let postBL = try #require(Self.buffer(width: 64, height: 64))
        let postEL = try #require(Self.buffer(width: 32, height: 32))
        r.decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        r.decoder.handleEnhancementLayerFrame(elBuffer: postEL, pts: Self.pts(1))
        r.decoder.handleBaseLayerFrame(baseBuffer: postBL, pts: Self.pts(1), hdr10Data: nil)
        try await waitFor { r.deliveries.afterMarker.count == 1 }

        // The pre-seek composition retires last, after the post-seek frame is already out.
        r.composer.releaseHeld()
        r.decoder.quiesceForTesting()

        let late = r.deliveries.afterMarker
        #expect(late.count == 1)
        #expect(late.first?.buffer === postBL)
        #expect(late.allSatisfy { $0.buffer !== staleBL })
        let pairs = r.composer.pairs
        #expect(pairs.count == 2)
        #expect(pairs.last?.base === postBL && pairs.last?.enhancement === postEL)
    }
}
#endif
