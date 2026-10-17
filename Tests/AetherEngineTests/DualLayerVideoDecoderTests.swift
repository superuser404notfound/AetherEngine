// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import Metal
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import Dovi
@_spi(Diagnostics) @testable import AetherEngine

/// `DualLayerVideoDecoder` pairs a 4K base-layer frame with its 1080p enhancement-layer frame and
/// the RPU cached for that PTS, composes them on the GPU, and delivers the result in decode order.
/// Both layers arrive on VideoToolbox callback threads, in either order, and compositions retire
/// asynchronously. These tests drive the two frame handlers directly with synthetic P010 buffers,
/// using `primeForTesting` / `seedRPUForTesting` to stand in for what `decode(packet:)` sets up, so
/// the pairing, ordering, metadata and flush behaviour is covered without a real stream.
@Suite(.serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)))
struct DualLayerVideoDecoderTests {

    // MARK: - Fixtures

    /// 23.976 fps at 90 kHz, rounded; only monotonic, well-separated keys matter here.
    private static let frameTicks: Int64 = 3754

    private static func pts(_ frame: Int64, offsetTicks: Int64 = 0) -> CMTime {
        CMTime(value: frame * frameTicks + offsetTicks, timescale: 90000)
    }

    private static var metalAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    private static func makeBuffer(width: Int, height: Int, fill: UInt16) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        guard status == kCVReturnSuccess, let buf = out else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buf) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buf, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(buf, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, plane)
            for r in 0..<rows {
                let row = base.advanced(by: r * stride).assumingMemoryBound(to: UInt16.self)
                for c in 0..<(stride / 2) { row[c] = fill }
            }
        }
        return buf
    }

    private static func baseLayer() -> CVPixelBuffer? { makeBuffer(width: 256, height: 256, fill: 0x8000) }
    private static func enhancementLayer() -> CVPixelBuffer? { makeBuffer(width: 128, height: 128, fill: 0x8000) }

    /// Identity reshaping at the test plane sizes; the plumbing is under test, not the curve.
    private static func params() -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = 256; p.blHeight = 256; p.elWidth = 128; p.elHeight = 128
        return p
    }

    /// A Profile 8.1 `unspec62` NAL shaped like `dovi_write_unspec62_nalu` output: header
    /// `0x7C 0x01`, then a payload starting with the RPU prefix `0x19`, tagged so frames differ.
    private static func rpuNAL(tag: UInt8) -> [UInt8] { [0x7C, 0x01, 0x19, 0x08, tag, 0xA5, 0x80] }

    /// Records what reached `onFrame`, reading the Dolby Vision attachments at delivery time,
    /// which is when the display layer would read them.
    private final class Deliveries: @unchecked Sendable {
        struct Frame {
            let buffer: CVPixelBuffer
            let pts: CMTime
            let hdr10: Data?
            let rpuPayload: Data?
            let compatibilityID: CFTypeRef?
            let afterMarker: Bool
        }

        private let lock = NSLock()
        private var frames: [Frame] = []
        private var marker = false

        func record(_ buffer: CVPixelBuffer, _ pts: CMTime, _ hdr10: Data?) {
            let payload = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data
            let compat = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.compatibilityIDKey as CFString, nil)
            lock.lock()
            frames.append(Frame(buffer: buffer, pts: pts, hdr10: hdr10, rpuPayload: payload,
                                compatibilityID: compat, afterMarker: marker))
            lock.unlock()
        }

        /// Marks the point a test's flush/close returned; frames delivered later carry the mark.
        func setMarker() { lock.lock(); marker = true; lock.unlock() }

        var snapshot: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    private static func decoder(recordingInto deliveries: Deliveries, enhancementLayer: Bool) -> DualLayerVideoDecoder {
        let decoder = DualLayerVideoDecoder()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: enhancementLayer)
        return decoder
    }

    private static func isStrictlyIncreasing(_ frames: [Deliveries.Frame]) -> Bool {
        zip(frames, frames.dropFirst()).allSatisfy { CMTimeCompare($0.pts, $1.pts) < 0 }
    }

    // MARK: - Single layer

    @Test("without an enhancement layer every base-layer frame is delivered untouched, in order")
    func singleLayerBypassesInOrder() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: false)
        defer { decoder.close() }
        var sent: [CVPixelBuffer] = []
        for i in 0..<5 {
            let bl = try #require(Self.baseLayer())
            sent.append(bl)
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }

        // A bypass is now a `fulfil` onto `OrderedDelivery`'s queue
        // (`queue.async`) rather than a synchronous call to `onFrame` on
        // whichever thread paired the frame, so `handleBaseLayerFrame`
        // returning is no longer a guarantee the frame has been delivered.
        try await waitFor { deliveries.count == 5 }
        let got = deliveries.snapshot
        #expect(got.count == 5)
        #expect(zip(got, sent).allSatisfy { $0.buffer === $1 })
        #expect(Self.isStrictlyIncreasing(got))
    }

    // MARK: - Pairing

    @Test("base layer first, then enhancement layer: the pair is composed and delivered at the base layer's PTS", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func pairsWhenBaseLayerArrivesFirst() async throws {
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)

        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(1), hdr10Data: nil)
        // Not `deliveries.count == 0`: delivery is one more `queue.async` hop
        // away, so that would hold whether or not the frame is still waiting.
        // `blQueueCount` is synchronous and deterministic:
        // `handleBaseLayerFrame` decides queued-vs-ticketed entirely under
        // `lock`, so by the time it returns, the frame is provably still
        // sitting in `blFrameQueue` (not bypassed, not composed) if and only
        // if it is still waiting for its enhancement layer.
        #expect(decoder.stateSnapshotForTesting.blQueueCount == 1, "a base-layer frame with a pending enhancement layer must wait for it")
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(1))

        try await waitFor { deliveries.count == 1 }
        let got = try #require(deliveries.snapshot.first)
        #expect(got.buffer !== bl, "expected the composer's output, got the bypassed base layer")
        #expect(CVPixelBufferGetWidth(got.buffer) == 256 && CVPixelBufferGetHeight(got.buffer) == 256)
        #expect(CMTimeCompare(got.pts, Self.pts(1)) == 0)
    }

    @Test("enhancement layer first, then base layer: the pair is composed and delivered at the base layer's PTS", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func pairsWhenEnhancementLayerArrivesFirst() async throws {
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)

        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(1))
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(1), hdr10Data: nil)

        try await waitFor { deliveries.count == 1 }
        let got = try #require(deliveries.snapshot.first)
        #expect(got.buffer !== bl)
        #expect(CMTimeCompare(got.pts, Self.pts(1)) == 0)
    }

    @Test("six enhancement-layer frames arriving ahead of the base layer all compose", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func pairsWhenEnhancementLayerRunsSixFramesAhead() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        for i in 0..<6 {
            let el = try #require(Self.enhancementLayer())
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
        }

        var sent: [CVPixelBuffer] = []
        for i in 0..<6 {
            let bl = try #require(Self.baseLayer())
            sent.append(bl)
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }

        try await waitFor { deliveries.count == 6 }
        let got = deliveries.snapshot
        #expect(got.count == 6)
        #expect(zip(got, sent).allSatisfy { $0.buffer !== $1 }, "every frame must use the composed path, not bypass for a missing EL")
        #expect(got.enumerated().allSatisfy { CMTimeCompare($0.element.pts, Self.pts(Int64($0.offset))) == 0 })
    }

    @Test("layers up to 300 ticks apart still pair; further apart they do not", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func jitterTolerance() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        let bl1 = try #require(Self.baseLayer())
        let el1 = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el1, pts: Self.pts(1, offsetTicks: 300))
        decoder.handleBaseLayerFrame(baseBuffer: bl1, pts: Self.pts(1), hdr10Data: nil)
        try await waitFor { deliveries.count == 1 }
        #expect(deliveries.count == 1)
        #expect(deliveries.snapshot.first?.buffer !== bl1)

        let bl2 = try #require(Self.baseLayer())
        let el2 = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(2), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el2, pts: Self.pts(2, offsetTicks: 301))
        decoder.handleBaseLayerFrame(baseBuffer: bl2, pts: Self.pts(2), hdr10Data: nil)
        decoder.quiesceForTesting()
        #expect(deliveries.count == 1, "301 ticks apart must not pair")
    }

    @Test("a pair with no cached RPU is not composed with invented coefficients: the base layer goes out", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func missingRPUBypassesToBaseLayer() async throws {
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(1))
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(1), hdr10Data: nil)

        try await waitFor { deliveries.count == 1 }
        #expect(deliveries.snapshot.first?.buffer === bl)
    }

    // MARK: - Ordering

    @Test("a composition still on the GPU is not overtaken by a later frame that bypasses synchronously", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func asyncCompositionKeepsItsPlace() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        for round in 0..<8 {
            let composed = Int64(round * 2), bypassed = Int64(round * 2 + 1)
            let bl0 = try #require(Self.baseLayer())
            let el0 = try #require(Self.enhancementLayer())
            let bl1 = try #require(Self.baseLayer())
            let el1 = try #require(Self.enhancementLayer())
            decoder.seedRPUForTesting(pts: Self.pts(composed), params: Self.params(), displayMetadataNAL: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el0, pts: Self.pts(composed))
            decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(composed), hdr10Data: nil)
            // No RPU for this one: it bypasses on the calling thread, ahead of the GPU.
            decoder.handleEnhancementLayerFrame(elBuffer: el1, pts: Self.pts(bypassed))
            decoder.handleBaseLayerFrame(baseBuffer: bl1, pts: Self.pts(bypassed), hdr10Data: nil)
        }

        try await waitFor { deliveries.count == 16 }
        let got = deliveries.snapshot
        #expect(got.count == 16)
        #expect(Self.isStrictlyIncreasing(got))
    }

    @Test("a base layer whose enhancement layer never arrives is still delivered, in order", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func orphanedBaseLayerIsEventuallyDelivered() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        let frames = 40
        for i in 0..<frames {
            let bl = try #require(Self.baseLayer())
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }

        // Every bypass goes through the async delivery hop. Wait for the bound
        // this test actually asserts (`frames - 16`), then drain the queue
        // for any stragglers still landing, before taking the final snapshot.
        try await waitFor { deliveries.count >= frames - 16 }
        decoder.quiesceForTesting()
        let got = deliveries.snapshot
        // Whatever the queue bound is, a lost enhancement layer must not swallow the picture:
        // all but a bounded tail of frames go out, as base layer, oldest first.
        #expect(got.count >= frames - 16)
        #expect(Self.isStrictlyIncreasing(got))
    }

    @Test("enhancement-layer frames with no base layer are bounded: the oldest can no longer pair", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func orphanedEnhancementLayersAreBounded() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        for i in 0..<40 {
            let el = try #require(Self.enhancementLayer())
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
        }
        let oldest = try #require(Self.baseLayer())
        let newest = try #require(Self.baseLayer())
        decoder.seedRPUForTesting(pts: Self.pts(0), params: Self.params(), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(39), params: Self.params(), displayMetadataNAL: nil)

        decoder.handleBaseLayerFrame(baseBuffer: oldest, pts: Self.pts(0), hdr10Data: nil)
        decoder.handleBaseLayerFrame(baseBuffer: newest, pts: Self.pts(39), hdr10Data: nil)
        // Frame 0's enhancement layer is gone, so it waits for `maxLayerSkewFrames` further base-layer
        // arrivals and then goes out alone; frame 39 is delivered behind it, in order. Without
        // these arrivals nothing is delivered at all, which an earlier version of this test read as a
        // pass: its bounded wait ran out and `first?.buffer !== newest` held for `nil`.
        for i in 0..<DualLayerVideoDecoder.maxLayerSkewFrames {
            let bl = try #require(Self.baseLayer())
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(40 + i)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count >= 2 }
        let got = deliveries.snapshot
        #expect(CMTimeCompare(got[0].pts, Self.pts(0)) == 0)
        #expect(got[0].buffer === oldest, "the enhancement layer for frame 0 should have been evicted: it goes out as its base layer")
        #expect(CMTimeCompare(got[1].pts, Self.pts(39)) == 0)
        #expect(got[1].buffer !== newest, "the newest enhancement layer should still pair")
    }

    // MARK: - Dolby Vision display metadata

    @Test("every delivered frame carries its own RPU payload; a frame without one borrows the previous frame's", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func displayMetadataTravelsWithItsFrame() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        for i in 0..<4 {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            let nal = Self.rpuNAL(tag: UInt8(i))
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nal)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        // Frame 4 has no RPU at all: it borrows frame 3's parameters and payload (E1), and the stale
        // attachment its recycled buffer arrived with must be replaced, not kept.
        decoder.seedRPUForTesting(pts: Self.pts(4), params: nil, displayMetadataNAL: nil)
        let recycled = try #require(Self.baseLayer())
        DoviDisplayMetadata.attach(rpuNAL: Self.rpuNAL(tag: 0xEE), to: recycled)
        decoder.handleBaseLayerFrame(baseBuffer: recycled, pts: Self.pts(4), hdr10Data: nil)
        let el4 = try #require(Self.enhancementLayer())
        decoder.handleEnhancementLayerFrame(elBuffer: el4, pts: Self.pts(4))

        try await waitFor { deliveries.count == 5 }
        let got = deliveries.snapshot
        #expect(got.count == 5)
        for i in 0..<4 where i < got.count {
            #expect(got[i].rpuPayload == Data(Self.rpuNAL(tag: UInt8(i)).dropFirst(2)), "frame \(i) carries the wrong RPU")
            #expect((got[i].compatibilityID as? String) == "1", "DolbyCompatibilityID must be the CFString \"1\"")
        }
        if got.count == 5 {
            #expect(got[4].rpuPayload == Data(Self.rpuNAL(tag: 3).dropFirst(2)), "a borrowed frame carries the previous payload")
            #expect((got[4].compatibilityID as? String) == "1")
        }
    }

    @Test("a run of use_prev_vdr_rpu_flag frames keeps composing with the previous mapping, past the corrupt-RPU borrow limit", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func usePreviousRunIsNotCapped() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        let frames = DualLayerVideoDecoder.maxBorrowedParamsRun + 6
        var inputs: [CVPixelBuffer] = []
        for i in 0..<frames {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            inputs.append(bl)
            if i == 0 {
                decoder.seedRPUForTesting(pts: Self.pts(0), params: Self.params(), displayMetadataNAL: Self.rpuNAL(tag: 0))
            } else {
                decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: nil, displayMetadataNAL: nil, usesPrevious: true)
            }
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count == frames }
        let got = deliveries.snapshot
        #expect(got.count == frames)
        // A bypassed frame is delivered as the base buffer itself; a composed one is a new pool buffer.
        for (i, f) in got.enumerated() where i < inputs.count {
            #expect(f.buffer !== inputs[i], "frame \(i) fell back to the base layer")
        }
    }

    /// Hands compositions straight back, remembering which parameters each base buffer was composed with.
    private final class ParamsRecordingComposer: FelComposing, @unchecked Sendable {
        private let lock = NSLock()
        private var _blMaxByBase: [ObjectIdentifier: UInt32] = [:]
        private var _flagsByBase: [ObjectIdentifier: DoviComposerFlags] = [:]
        func blMax(of base: CVPixelBuffer) -> UInt32? {
            lock.lock(); defer { lock.unlock() }
            return _blMaxByBase[ObjectIdentifier(base)]
        }
        func flags(of base: CVPixelBuffer) -> DoviComposerFlags? {
            lock.lock(); defer { lock.unlock() }
            return _flagsByBase[ObjectIdentifier(base)]
        }
        func acquireSlot() {}
        func releaseSlot() {}
        func flush() {}
        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            composeAsyncWithAcquiredSlot(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer,
                                         params: params, frameIndex: frameIndex, completion: completion)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer,
                                          params: DoviMetalParams, frameIndex: UInt32,
                                          completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            lock.lock()
            _blMaxByBase[ObjectIdentifier(baseBuffer)] = params.blMax
            _flagsByBase[ObjectIdentifier(baseBuffer)] = params.flags
            lock.unlock()
            completion(baseBuffer)
        }
    }

    @Test("the previous mapping is the previous frame in the stream, not the previous frame to finish pairing")
    func previousMappingFollowsDecodeOrder() async throws {
        let composer = ParamsRecordingComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)

        func mapping(_ tag: UInt32) -> DoviMetalParams { var p = Self.params(); p.blMax = tag; return p }
        // Packets, in decode order: A, B, "same as before", an RPU that failed, then C.
        decoder.seedRPUForTesting(pts: Self.pts(0), params: mapping(100), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: mapping(200), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(2), params: nil, displayMetadataNAL: nil, usesPrevious: true)
        decoder.seedRPUForTesting(pts: Self.pts(3), params: nil, displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(4), params: mapping(300), displayMetadataNAL: nil)

        // The layers pair in a different order: 0, then 4 and 2 and 3 before 1.
        var bases: [Int: CVPixelBuffer] = [:]
        for frame in [0, 4, 2, 3, 1] {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            bases[frame] = bl
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(frame)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(frame)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count == 5 }
        let blMax = (0..<5).map { composer.blMax(of: bases[$0]!) }
        #expect(blMax == [100, 200, 200, 200, 300])
    }

    @Test("a use_prev frame keeps the previous mapping but takes its own disable_residual_flag")
    func usePreviousTakesOwnResidualFlag() async throws {
        let composer = ParamsRecordingComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)

        var full = Self.params(); full.blMax = 100
        var noResidual = full; noResidual.flags.insert(.disableResidual)
        // A residual-less RPU, then "same mapping" frames that switch the residual on and off again.
        decoder.seedRPUForTesting(pts: Self.pts(0), params: noResidual, displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: nil, displayMetadataNAL: nil, usesPrevious: true, disableResidual: false)
        decoder.seedRPUForTesting(pts: Self.pts(2), params: nil, displayMetadataNAL: nil, usesPrevious: true, disableResidual: true)

        var bases: [CVPixelBuffer] = []
        for frame in 0..<3 {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            bases.append(bl)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(frame)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(frame)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count == 3 }
        #expect(bases.map { composer.blMax(of: $0) } == [100, 100, 100], "the mapping carries over")
        #expect(bases.map { composer.flags(of: $0)?.contains(.disableResidual) } == [true, false, true],
                "each frame's own disable_residual_flag wins over the borrowed parameters'")
    }

    #if DEBUG
    @Test("side data recorded for post-seek packets while flush() drains survives the flush and composes")
    func sideDataRecordedDuringTheDrainSurvivesFlush() async throws {
        let composer = ParamsRecordingComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        defer {
            decoder.flushRaceHookForTesting = nil
            decoder.close()
        }

        func mapping(_ tag: UInt32) -> DoviMetalParams { var p = Self.params(); p.blMax = tag; return p }
        // A pre-seek RPU that the flush must discard, and a post-seek one the demux thread records
        // while the hardware drain is still running (the hook runs between the two critical sections).
        decoder.seedRPUForTesting(pts: Self.pts(0), params: mapping(100), displayMetadataNAL: nil)
        decoder.flushRaceHookForTesting = { [weak decoder] in
            decoder?.seedRPUForTesting(pts: Self.pts(10), params: mapping(777), displayMetadataNAL: nil)
        }
        decoder.flush()

        let staleBL = try #require(Self.baseLayer())
        let staleEL = try #require(Self.enhancementLayer())
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        decoder.handleEnhancementLayerFrame(elBuffer: staleEL, pts: Self.pts(0))
        decoder.handleBaseLayerFrame(baseBuffer: staleBL, pts: Self.pts(0), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(10))
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(10), hdr10Data: nil)
        try await waitFor { deliveries.count == 2 }
        #expect(composer.blMax(of: bl) == 777, "the RPU recorded during the drain must compose its frame")
        #expect(composer.blMax(of: staleBL) == nil, "the pre-seek RPU is gone")
    }

    @Test("two flushes gated at the same point run one after the other: no interleaving, no stall, no stale delivery")
    func concurrentFlushesAreSerialised() async throws {
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: false)
        defer {
            decoder.flushRaceHookForTesting = nil
            decoder.close()
        }
        for i in 0..<3 {
            let bl = try #require(Self.baseLayer())
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count == 3 }

        let firstInHook = BoolFlag()
        let hookCalls = LockedCounter()
        let release = DispatchSemaphore(value: 0)
        decoder.flushRaceHookForTesting = {
            // Only the first flush to get here is held; the second must never get this far while it is.
            if hookCalls.incrementAndCheckFirst() {
                firstInHook.set()
                release.wait()
            }
        }
        let epochBefore = decoder.feedEpoch
        let firstDone = BoolFlag()
        let secondDone = BoolFlag()
        BlockingWork.detached { decoder.flush(); firstDone.set() }
        try await waitFor { firstInHook.isSet }
        #expect(decoder.feedEpoch == epochBefore + 1)

        let secondArrived = BoolFlag()
        decoder.flushWillTakeLifecycleLockHookForTesting = { secondArrived.set() }
        BlockingWork.detached { decoder.flush(); secondDone.set() }
        // The second flush must stay out of its critical section (the epoch must not move, `draining`
        // must stay owned by the first) while the first is held. Wait until it has reached the lock,
        // by a hook rather than by a delay, then check: if the lock were missing it would be past
        // the epoch bump within a few instructions, and `release` is still unsignalled, so the first
        // flush cannot be what moved it.
        try await waitFor { secondArrived.isSet }
        #expect(!secondDone.isSet)
        #expect(decoder.feedEpoch == epochBefore + 1, "the second flush interleaved with the first")

        release.signal()
        try await waitFor { firstDone.isSet && secondDone.isSet }
        #expect(decoder.feedEpoch == epochBefore + 2)

        // Delivery works afterwards: new frames take tickets under the final epoch and come out in order.
        for i in 3..<6 {
            let bl = try #require(Self.baseLayer())
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count == 6 }
        let got = deliveries.snapshot
        #expect(got.count == 6, "a frame was delivered twice or a ticket was lost")
        #expect(Self.isStrictlyIncreasing(got))
    }
    #endif

    @Test("composedFrameCount counts compositions only, not bypasses, and survives flush()")
    func composedFrameCountIgnoresBypassesAndFlush() async throws {
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: ParamsRecordingComposer())
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        #expect(decoder.composedFrameCount == 0)

        // Frame 0 has an RPU and its enhancement layer: composed. Frame 1 has no RPU: bypassed.
        decoder.seedRPUForTesting(pts: Self.pts(0), params: Self.params(), displayMetadataNAL: nil)
        for frame in 0..<2 {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(frame)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(frame)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count == 2 }
        #expect(decoder.composedFrameCount == 1)
        decoder.flush()
        #expect(decoder.composedFrameCount == 1, "the 1 Hz summary and flush reset their own counters, not this one")
    }

    @Test("frames without a timestamp pair with nothing, and never trap the key arithmetic")
    func missingTimestampNeverMatchesOrTraps() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }
        let waitingBL = try #require(Self.baseLayer())
        let waitingEL = try #require(Self.enhancementLayer())
        let noPtsBL = try #require(Self.baseLayer())
        let noPtsEL = try #require(Self.enhancementLayer())

        // A base-layer frame and an enhancement-layer frame are each waiting on a partner at a normal time.
        decoder.handleBaseLayerFrame(baseBuffer: waitingBL, pts: Self.pts(5), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: waitingEL, pts: Self.pts(9))
        // Then a frame of each layer arrives with no PTS (`AV_NOPTS_VALUE` is `Int64.min`).
        decoder.handleEnhancementLayerFrame(elBuffer: noPtsEL, pts: .invalid)
        decoder.handleBaseLayerFrame(baseBuffer: noPtsBL, pts: .invalid, hdr10Data: nil)

        // The enhancement layer without a timestamp was dropped, and the two waiting frames are untouched.
        let snapshot = decoder.stateSnapshotForTesting
        #expect(snapshot.elQueueCount == 1)
        #expect(snapshot.blQueueCount == 1)
        // The base layer without a timestamp bypassed at once, but under its own ticket: it stays behind
        // the waiting frame that arrived first.
        #expect(deliveries.count == 0)
        // Completing the waiting pair releases both, in arrival order.
        decoder.handleEnhancementLayerFrame(elBuffer: Self.enhancementLayer()!, pts: Self.pts(5))
        try await waitFor { deliveries.count == 2 }
        #expect(deliveries.snapshot.last?.buffer === noPtsBL)
    }

    @Test("the side-data ring does not trap on, or match, a missing key")
    func ringIgnoresMissingKeys() {
        var ring = FrameSideDataRing()
        ring.insert(key: 1_000_000, params: DoviMetalParams(), dmNAL: [1, 2, 3])
        ring.insert(key: -5_000_000_000, params: DoviMetalParams())
        #expect(ring.find(key: Int64.min) == nil)
        #expect(ring.removeParams(key: Int64.min) == nil)
        #expect(ring.removeDisplayMetadata(key: Int64.min) == nil)
        #expect(ring.count == 2)
        #expect(FrameSideDataRing.distance(Int64.max, -Int64.max) == nil)
        #expect(FrameSideDataRing.distance(10, 4) == 6)
        #expect(!FrameSideDataRing.isWithinJitter(Int64.min, Int64.min))
        #expect(FrameSideDataRing.isWithinJitter(1000, 1300))
        #expect(!FrameSideDataRing.isWithinJitter(1000, 1301))
    }

    // MARK: - Flush and close

    @Test("nothing composed before a flush is delivered after the flush returns", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func flushRetiresOutstandingFrames() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        for i in 0..<6 {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        decoder.flush()
        deliveries.setMarker()

        // The decoder is usable after a flush: a fresh single-layer frame goes straight out.
        decoder.primeForTesting(enhancementLayer: false)
        let after = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: after, pts: Self.pts(100), hdr10Data: nil)
        decoder.quiesceForTesting()

        let late = deliveries.snapshot.filter { $0.afterMarker }
        #expect(late.count == 1)
        #expect(late.first?.buffer === after)
    }

    @Test("nothing is delivered after close returns", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func closeStopsDelivery() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)

        for i in 0..<6 {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        decoder.close()
        deliveries.setMarker()
        decoder.quiesceForTesting()

        #expect(deliveries.snapshot.allSatisfy { !$0.afterMarker })
    }

    @Test("close resets stream state and the decoder refuses to reopen")
    func closeResetsStreamStateAndRefusesReopen() async throws {
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }

        // Latch the MEL state a reopened instance must never inherit.
        decoder.primeStreamForTesting(.mel)
        #expect(decoder.streamClassificationForTesting == .mel)

        decoder.close()

        let snap = decoder.stateSnapshotForTesting
        #expect(snap.isClosed)
        #expect(!snap.isFEL && !snap.isMEL && !snap.streamClassified)
        #expect(!snap.primaryDecoderInitialized)
        #expect(!snap.enhancementEngaged)
        #expect(snap.frameIndex == 0)
        #expect(snap.blQueueCount == 0)
        #expect(snap.elQueueCount == 0)
        #expect(snap.rpuCacheCount == 0)
        #expect(snap.dmRpuCacheCount == 0)
        #expect(snap.deliveryPendingCount == 0)
        #expect(snap.deliveryNextTicket == 0)
        #expect(snap.deliveryNextToEmit == 0)
        // Additional fields made explicit in snapshot (cheap to check):
        #expect(!snap.draining)
        #expect(snap.timeBaseNum == 1 && snap.timeBaseDen == 90000)
        #expect(!snap.hasBLVPS && !snap.hasBLSPS && !snap.hasBLPPS)
        #expect(!snap.hasELVPS && !snap.hasELSPS && !snap.hasELPPS)
        #expect(!snap.hasSkipUntilPTS)
        #expect(!snap.hasOnFrame)

        // Single use: `open` after `close` refuses. `open` checks the flag
        // before touching `stream`, so uninitialized storage suffices here.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AVStream>.size,
            alignment: MemoryLayout<AVStream>.alignment)
        defer { raw.deallocate() }
        let stream = raw.assumingMemoryBound(to: AVStream.self)
        do {
            try decoder.open(stream: stream) { _, _, _ in }
            Issue.record("open after close must refuse with VideoDecoderError.decoderClosed")
        } catch VideoDecoderError.decoderClosed {
            // Expected: single-use decoder.
        }

        // A post-close base-layer frame must not reach the cleared `onFrame`.
        // `isClosed` gates `handleBaseLayerFrame` before any ticket is issued;
        // settling before the negative check makes that hold by construction,
        // as in every other post-teardown check in this file.
        let bl = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(0), hdr10Data: nil)
        decoder.quiesceForTesting()
        #expect(deliveries.count == 0)
        #expect(decoder.stateSnapshotForTesting.deliveryPendingCount == 0)

        // decode-after-close early-returns before touching the packet payload:
        // the entry gate refuses without forwarding to either sub-decoder.
        let packet = try #require(av_packet_alloc())
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        decoder.decode(packet: packet)
        decoder.decode(packet: packet, epoch: decoder.feedEpoch)
        // No sub-decoders to check here (real decoders), but entry gate blocks.

        // flush-after-close is a no-op: still closed, epoch untouched, silent.
        decoder.flush()
        #expect(decoder.stateSnapshotForTesting.isClosed)
        #expect(decoder.feedEpoch == decoder.stateSnapshotForTesting.feedEpoch)

        // Double close is safe and idempotent.
        decoder.close()
        #expect(decoder.stateSnapshotForTesting.isClosed)
    }

    @Test("decode and flush after close are no-ops; double close is safe")
    func closeRefusesDecodeAndFlushAndDoubleClose() async throws {
        let primary = CountingFakeDecoder()
        let enhancement = CountingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        let deliveries = Deliveries()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)

        let epochBeforeClose = decoder.feedEpoch
        decoder.close()
        let snap = decoder.stateSnapshotForTesting
        #expect(snap.isClosed)
        #expect(snap.blQueueCount == 0 && snap.elQueueCount == 0)
        #expect(snap.rpuCacheCount == 0 && snap.dmRpuCacheCount == 0)
        #expect(snap.deliveryPendingCount == 0)
        #expect(decoder.feedEpoch == epochBeforeClose + 1)

        // decode-after-close early-returns before touching the packet payload:
        // the entry gate refuses without forwarding to either sub-decoder.
        let packet = try #require(av_packet_alloc())
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        decoder.decode(packet: packet)
        decoder.decode(packet: packet, epoch: decoder.feedEpoch)
        #expect(primary.decodeCount == 0)
        #expect(enhancement.decodeCount == 0)
        #expect(!decoder.stateSnapshotForTesting.enhancementEngaged)

        // flush-after-close is a no-op: still closed, epoch untouched, silent.
        decoder.flush()
        #expect(decoder.stateSnapshotForTesting.isClosed)
        #expect(decoder.feedEpoch == epochBeforeClose + 1)
        #expect(primary.flushCount == 0)
        #expect(enhancement.flushCount == 0)

        // Post-close frame handlers and in-flight deliveries stay silent and
        // issue no tickets.
        let ticketsBefore = decoder.stateSnapshotForTesting.deliveryNextTicket
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(0), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(0))
        decoder.quiesceForTesting()
        #expect(deliveries.count == 0)
        #expect(decoder.stateSnapshotForTesting.deliveryNextTicket == ticketsBefore)

        // Double close is safe and idempotent.
        decoder.close()
        #expect(decoder.stateSnapshotForTesting.isClosed)
        #expect(primary.closeCount >= 1)
        decoder.quiesceForTesting()
        #expect(deliveries.count == 0)
    }

    @Test("frames emitted from inside flush() are dropped and never delivered")
    func flushDropsFramesEmittedFromInsideFlush() async throws {
        // Synchronous composer, so any composition a drained frame managed to
        // start would retire — and deliver — on the calling thread. If nothing
        // arrives, the draining gate held on every path.
        let primary = FlushEmittingFakeDecoder()
        let enhancement = FlushEmittingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        let deliveries = Deliveries()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        defer { decoder.close() }

        let drainBL0 = try #require(Self.baseLayer())
        let drainEL0 = try #require(Self.enhancementLayer())
        let drainBL2 = try #require(Self.baseLayer())
        let drainEL2 = try #require(Self.enhancementLayer())
        let pre0 = SendableFrameBuffer(value: drainBL0)
        let pre0e = SendableFrameBuffer(value: drainEL0)
        let pre2 = SendableFrameBuffer(value: drainBL2)
        let pre2e = SendableFrameBuffer(value: drainEL2)
        decoder.seedRPUForTesting(pts: Self.pts(0), params: Self.params(), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(2), params: Self.params(), displayMetadataNAL: nil)
        // What the installed `onFrame` closures would do with owed pre-seek
        // frames: re-enter the pairing handlers from inside the flush, in both
        // arrival orders (primary drains first, then enhancement).
        primary.emitFromInsideFlush = {
            decoder.handleBaseLayerFrame(baseBuffer: pre0.value, pts: Self.pts(0), hdr10Data: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: pre0e.value, pts: Self.pts(0))
        }
        enhancement.emitFromInsideFlush = {
            decoder.handleEnhancementLayerFrame(elBuffer: pre2e.value, pts: Self.pts(2))
            decoder.handleBaseLayerFrame(baseBuffer: pre2.value, pts: Self.pts(2), hdr10Data: nil)
        }

        decoder.flush()
        decoder.quiesceForTesting()
        #expect(deliveries.count == 0, "pre-seek frames drained during flush() must never be delivered")

        // The decoder is usable after the flush: a fresh pair composes and delivers.
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(1))
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(1), hdr10Data: nil)
        // Even a synchronous composition's delivery is one more
        // `queue.async` hop through `OrderedDelivery` away, so
        // `handleBaseLayerFrame` returning is not a guarantee `onFrame` has
        // run yet for it.
        try await waitFor { deliveries.count == 1 }
        #expect(deliveries.count == 1)
        #expect(CMTimeCompare(deliveries.snapshot.first?.pts ?? .invalid, Self.pts(1)) == 0)
    }

    @Test("the end-of-stream drain delivers the frames the sessions still owe, paired or alone, in order")
    func endOfStreamDrainDeliversOwedFrames() async throws {
        let primary = FlushEmittingFakeDecoder()
        let enhancement = FlushEmittingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        let deliveries = Deliveries()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        defer { decoder.close() }

        let bl: [SendableFrameBuffer] = try (0..<3).map { _ in
            guard let b = Self.baseLayer() else { throw CancellationError() }
            return SendableFrameBuffer(value: b)
        }
        let el: [SendableFrameBuffer] = try (0..<2).map { _ in
            guard let e = Self.enhancementLayer() else { throw CancellationError() }
            return SendableFrameBuffer(value: e)
        }
        for i in 0..<3 {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
        }
        // The last frames of a stream, still inside the sessions after the last packet was fed: three
        // base-layer frames, and enhancement-layer frames for the first two only.
        primary.emitFromInsideFlush = {
            for i in 0..<3 {
                decoder.handleBaseLayerFrame(baseBuffer: bl[i].value, pts: Self.pts(Int64(i)), hdr10Data: nil)
            }
        }
        enhancement.emitFromInsideFlush = {
            for i in 0..<2 {
                decoder.handleEnhancementLayerFrame(elBuffer: el[i].value, pts: Self.pts(Int64(i)))
            }
        }

        decoder.drainForEndOfStream()
        // No wait: the drain returns once its frames have reached `onFrame`.
        let frames = deliveries.snapshot
        #expect(frames.count == 3)
        #expect(frames.map { ObjectIdentifier($0.buffer) } == bl.map { ObjectIdentifier($0.value) })
        #expect(Self.isStrictlyIncreasing(frames))
        #expect(decoder.composedFrameCount == 2, "the two frames with an enhancement layer are composed")
        #expect(decoder.stateSnapshotForTesting.blQueueCount == 0)

        // The host's flush that follows has nothing left to drop or deliver.
        primary.emitFromInsideFlush = nil
        enhancement.emitFromInsideFlush = nil
        decoder.flush()
        decoder.quiesceForTesting()
        #expect(deliveries.count == 3)
    }

    // MARK: - Session loss (AE#739)

    @Test("the session-loss handler reaches both layers' decoders, once per loss, and clearing it clears both")
    func sessionLostHandlerReachesBothLayers() {
        let primary = HardwareVideoDecoder()
        let enhancement = HardwareVideoDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        defer { decoder.close() }
        let calls = SessionLossCount()
        decoder.onSessionLost = { calls.bump() }
        // A screen lock loses both sessions and each layer reports it: one recovery, not two.
        primary.onSessionLost?()
        enhancement.onSessionLost?()
        #expect(calls.value == 1)
        // After a rebuild (refused here: neither decoder was opened) the next loss is reported again.
        _ = decoder.rebuildSession()
        enhancement.onSessionLost?()
        #expect(calls.value == 2)
        decoder.onSessionLost = nil
        #expect(primary.onSessionLost == nil)
        #expect(enhancement.onSessionLost == nil)
    }

    @Test("a closed decoder refuses a session rebuild")
    func closedDecoderRefusesRebuild() {
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: FlushEmittingFakeDecoder(),
            enhancementDecoder: FlushEmittingFakeDecoder()
        )
        #expect(decoder.rebuildSession())
        decoder.close()
        #expect(!decoder.rebuildSession())
    }

    @Test("after a session rebuild both layers are back on the decoder's epoch, so later packets are accepted")
    func rebuildAdoptsFeedEpoch() {
        let primary = EpochRecordingFakeDecoder()
        let enhancement = EpochRecordingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        defer { decoder.close() }
        decoder.flush()
        let epoch = decoder.feedEpoch
        #expect(epoch > 0)
        // A rebuilt hardware decoder moves its own epoch; the dual decoder must put it back.
        primary.epoch = epoch &+ 7
        enhancement.epoch = epoch &+ 9
        #expect(decoder.rebuildSession())
        #expect(primary.epoch == epoch)
        #expect(enhancement.epoch == epoch)
        #expect(decoder.feedEpoch == epoch)
    }

    @Test("the host's drain reaches the dual-layer decoder through the pipeline protocol; a plain decoder's is a no-op")
    func drainDispatchesThroughProtocol() {
        let primary = FlushEmittingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: nil
        )
        defer { decoder.close() }
        var flushedByDrain = 0
        primary.emitFromInsideFlush = { flushedByDrain += 1 }
        let pipeline: any VideoDecodingPipeline = decoder
        pipeline.drainForEndOfStream()
        #expect(flushedByDrain == 1)
        // A decoder whose flush delivers needs no drain.
        let plain: any VideoDecodingPipeline = FlushEmittingFakeDecoder()
        plain.drainForEndOfStream()
    }

    private final class EpochRecordingFakeDecoder: SingleLayerVideoDecoder, @unchecked Sendable {
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        var epoch: UInt64 = 0
        var feedEpoch: UInt64 { epoch }
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
            self.onFrame = onFrame
        }
        func open(parameterSets: [[UInt8]], timeBase: AVRational, onFrame: @escaping DecodedFrameHandler) throws {
            self.onFrame = onFrame
        }
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {}
        func flush() {}
        func adoptFeedEpoch(_ epoch: UInt64) { self.epoch = epoch }
        func close() { onFrame = nil }
    }

    private final class SessionLossCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: - Thread safety

    /// Synchronous composer so the stress test needs no GPU: every composition
    /// retires on the calling thread instead of on a Metal completion queue.
    ///
    /// Delivery is still asynchronous: every frame, composed or bypassed, is
    /// one more `queue.async` hop away from `onFrame` regardless of how this
    /// fake calls its `completion`. What this fake buys a test: pairing and composition finish deterministically, in program
    /// order, with no GPU and no wait for a command buffer to retire, so a
    /// test can reason about ticket order and queue depth without also
    /// reasoning about the exactly-once assertions being asynchronous;
    /// tests below still have to wait for the frame to actually leave
    /// `OrderedDelivery`'s own queue (`waitFor`/`settle`).
    private final class ImmediateFakeComposer: FelComposing, @unchecked Sendable {
        func acquireSlot() {}
        func releaseSlot() {}
        func flush() {}
        func composeAsync(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            completion(baseBuffer)
        }
        func composeAsyncWithAcquiredSlot(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            completion(baseBuffer)
        }
    }

    private struct SendableFrameBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    /// Fake single-layer decoder: runs a hook from inside `flush()`,
    /// the way `HardwareVideoDecoder.flush()` re-enters the frame callbacks
    /// with the frames VideoToolbox still owes while the host thread is
    /// blocked inside the flush.
    private final class FlushEmittingFakeDecoder: SingleLayerVideoDecoder, @unchecked Sendable {
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        var feedEpoch: UInt64 = 0
        var emitFromInsideFlush: (() -> Void)?
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
            self.onFrame = onFrame
        }
        func open(
            parameterSets: [[UInt8]],
            timeBase: AVRational,
            onFrame: @escaping DecodedFrameHandler
        ) throws {
            self.onFrame = onFrame
        }
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {}
        func flush() { emitFromInsideFlush?() }
        func close() { onFrame = nil }
    }

    /// Counting fake: records sub-decoder traffic so tests can prove
    /// post-close `decode`/`flush` never reach the torn-down sessions.
    private final class CountingFakeDecoder: SingleLayerVideoDecoder, @unchecked Sendable {
        private let lock = NSLock()
        private var _decodeCount = 0
        private var _flushCount = 0
        private var _closeCount = 0
        var decodeCount: Int { lock.lock(); defer { lock.unlock() }; return _decodeCount }
        var flushCount: Int { lock.lock(); defer { lock.unlock() }; return _flushCount }
        var closeCount: Int { lock.lock(); defer { lock.unlock() }; return _closeCount }
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        var feedEpoch: UInt64 = 0
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
            self.onFrame = onFrame
        }
        func open(
            parameterSets: [[UInt8]],
            timeBase: AVRational,
            onFrame: @escaping DecodedFrameHandler
        ) throws {
            self.onFrame = onFrame
        }
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {
            lock.lock(); _decodeCount += 1; lock.unlock()
        }
        func flush() { lock.lock(); _flushCount += 1; lock.unlock() }
        func close() { lock.lock(); _closeCount += 1; lock.unlock(); onFrame = nil }
    }

    @Test("concurrent layer arrivals and control-plane churn keep exactly-once delivery; close under load stays silent")
    func concurrentArrivalsAndTeardown() async throws {
        let frames = 64
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        for i in 0..<frames {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
        }
        let bl: [SendableFrameBuffer] = try (0..<frames).map { _ in
            guard let b = Self.baseLayer() else { throw CancellationError() }
            return SendableFrameBuffer(value: b)
        }
        let el: [SendableFrameBuffer] = try (0..<frames).map { _ in
            guard let e = Self.enhancementLayer() else { throw CancellationError() }
            return SendableFrameBuffer(value: e)
        }

        let group = DispatchGroup()
        for i in 0..<frames {
            group.enter()
            DispatchQueue.global().async {
                // Alternate arrival order per pair to hit both pairing paths.
                if i % 2 == 0 {
                    decoder.handleBaseLayerFrame(baseBuffer: bl[i].value, pts: Self.pts(Int64(i)), hdr10Data: nil)
                    decoder.handleEnhancementLayerFrame(elBuffer: el[i].value, pts: Self.pts(Int64(i)))
                } else {
                    decoder.handleEnhancementLayerFrame(elBuffer: el[i].value, pts: Self.pts(Int64(i)))
                    decoder.handleBaseLayerFrame(baseBuffer: bl[i].value, pts: Self.pts(Int64(i)), hdr10Data: nil)
                }
                group.leave()
            }
            // Control-plane churn on the same shared state the VT threads touch.
            group.enter()
            DispatchQueue.global().async {
                decoder.skipUntilPTS = Self.pts(Int64(i))
                _ = decoder.skipUntilPTS
                _ = decoder.streamClassificationForTesting
                _ = decoder.engagesEnhancementLayerForTesting()
                decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
                group.leave()
            }
        }
        // `notify` parks nothing; a hang is reported by the suite's `.timeLimit`.
        await withCheckedContinuation { cont in group.notify(queue: .global()) { cont.resume() } }

        // Every base layer is delivered exactly once however it got out (paired,
        // pruned or bypassed); enhancement-only orphans never deliver alone.
        // The `DispatchGroup` above only covers pairing — each frame's
        // actual delivery is one more `queue.async` hop through
        // `OrderedDelivery` beyond that, so it can still be in flight once
        // every pairing call has returned.
        let sentIDs = Set(bl.map { ObjectIdentifier($0.value) })
        var nudgeIDs: Set<ObjectIdentifier> = []
        do {
            // Nudged unconditionally, so the test does not have to decide by a timeout whether
            // frames are stranded. `collectDueBypasses` ages a queued base-layer frame out after
            // `K` further base-layer *arrivals*, not elapsed time, and only runs from inside
            // `handleBaseLayerFrame`. This test's 64-way unthrottled fan-out delivers each layer
            // out of decode order essentially every run (measured: 2–3 of 64 base-layer frames
            // stranded in `blFrameQueue` in 40 of 40 runs; two threads delivering each layer in
            // decode order stranded 0 of 40). That cannot happen mid-stream in production, where
            // VideoToolbox outputs each layer in decode order; the only production exposure is
            // the last base-layer frames at end of stream whose enhancement layer never arrives,
            // which is the K-frame bound itself. A base layer can be scheduled so late that
            // "newest settled base layer" has already raced ahead of it; its enhancement layer is
            // then correctly dropped as stale, and no further base-layer arrival happens within
            // this batch to age it out before the `DispatchGroup` above finishes. It is still
            // queued, not lost: a few harmless, never-pairing nudges (fresh buffers, PTS values
            // outside this test's range) advance `blArrivalSeq` past it.
            for i in 0..<(DualLayerVideoDecoder.maxLayerSkewFrames + 1) {
                guard let nudge = Self.baseLayer() else { break }
                nudgeIDs.insert(ObjectIdentifier(nudge))
                decoder.handleBaseLayerFrame(baseBuffer: nudge, pts: Self.pts(Int64(900 + i)), hdr10Data: nil)
            }
            try await waitFor {
                deliveries.snapshot.filter { sentIDs.contains(ObjectIdentifier($0.buffer)) }.count >= frames
            }
        }
        // `allSatisfy`, not a `filter`: an enhancement-layer buffer (or
        // anything else) delivered on its own is what this catches; sent
        // base-layer frames and the nudges above are the only buffers ever
        // allowed out.
        let allowed = sentIDs.union(nudgeIDs)
        #expect(deliveries.snapshot.allSatisfy { allowed.contains(ObjectIdentifier($0.buffer)) },
                "only sent base-layer frames or the nudges that age out stranded ones may ever be delivered")
        let got = deliveries.snapshot.filter { sentIDs.contains(ObjectIdentifier($0.buffer)) }
        #expect(got.count == frames)
        #expect(Set(got.map { ObjectIdentifier($0.buffer) }).count == frames)

        // Teardown under load: arrivals racing close() are either delivered
        // before it or dropped after it; nothing lands past the marker.
        let teardown = DispatchGroup()
        for i in frames..<(frames + 8) {
            teardown.enter()
            DispatchQueue.global().async {
                if let b = Self.baseLayer(), let e = Self.enhancementLayer() {
                    decoder.handleBaseLayerFrame(baseBuffer: b, pts: Self.pts(Int64(i)), hdr10Data: nil)
                    decoder.handleEnhancementLayerFrame(elBuffer: e, pts: Self.pts(Int64(i)))
                }
                teardown.leave()
            }
        }
        teardown.enter()
        DispatchQueue.global().async {
            decoder.flush()
            decoder.close()
            teardown.leave()
        }
        await withCheckedContinuation { cont in teardown.notify(queue: .global()) { cont.resume() } }
        deliveries.setMarker()
        if let b = Self.baseLayer(), let e = Self.enhancementLayer() {
            decoder.handleBaseLayerFrame(baseBuffer: b, pts: Self.pts(10_000), hdr10Data: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: e, pts: Self.pts(10_000))
        }
        decoder.quiesceForTesting()
        #expect(deliveries.snapshot.allSatisfy { !$0.afterMarker })
    }

    // MARK: - Delivery queue

    /// Fake composer whose every composition fails (completes with nil), as a GPU error does.
    private final class FailingFakeComposer: FelComposing, @unchecked Sendable {
        func acquireSlot() {}
        func releaseSlot() {}
        func flush() {}
        func composeAsync(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            completion(nil)
        }
        func composeAsyncWithAcquiredSlot(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            completion(nil)
        }
    }

    /// Fake composer whose Nth call (1-indexed) never calls its completion at
    /// all — the one failure mode a ticket cannot self-report, unlike a
    /// bypass or a "compose failed" fallback. Every other call completes
    /// synchronously with the base layer, like `ImmediateFakeComposer`.
    private final class DroppingFakeComposer: FelComposing, @unchecked Sendable {
        private let dropOnCall: Int
        private let lock = NSLock()
        private var calls = 0
        init(dropOnCall: Int) { self.dropOnCall = dropOnCall }
        func acquireSlot() {}
        func releaseSlot() {}
        func flush() {}
        func composeAsync(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            composeAsyncWithAcquiredSlot(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer, params: params, frameIndex: frameIndex, completion: completion)
        }
        func composeAsyncWithAcquiredSlot(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            if n == dropOnCall {
                // Simulates a completion that never fires: no call to
                // `completion`, so the ticket this composition took is never
                // fulfilled at all.
                return
            }
            completion(baseBuffer)
        }
    }

    @Test("a composition whose completion never fires costs exactly one frame, not the session")
    func lostCompletionCostsExactlyOneFrame() async throws {
        let threshold = DoviFelComposer.maxFramesInFlight + DualLayerVideoDecoder.maxLayerSkewFrames + 2
        let composer = DroppingFakeComposer(dropOnCall: 1)
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        defer { decoder.close() }

        // Every frame pairs immediately (EL arrives first, so `handleBaseLayerFrame`
        // composes on the spot) so ticket `i` and loop index `i` coincide. The
        // first composition's ticket (0) is the one `DroppingFakeComposer` drops;
        // enough frames follow to push it past `orderedDelivery`'s stall
        // threshold (`maxFramesInFlight + K + 2`).
        let frames = threshold + 6
        for i in 0..<frames {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }

        try await waitFor { deliveries.count == frames - 1 }
        let got = deliveries.snapshot
        #expect(got.count == frames - 1, "every frame but the one lost ticket must still be delivered")
        #expect(Self.isStrictlyIncreasing(got), "the stall guard must not disturb the order of the frames it does deliver")
    }

    #if DEBUG
    @Test("a ticket raced into the gap between flush()'s unlock and its delivery barrier is not lost")
    func flushDoesNotLosePostFlushTicketInTheUnlockToBarrierGap() async throws {
        // Regression test for an ordering race in `flush()`: drives a ticket
        // through the window a post-flush ticket could be lost in —
        // right after the critical section that bumps `_feedEpoch`, captures
        // `nextTicket` and enqueues `orderedDelivery.resetAsync` releases
        // `lock`, but before `orderedDelivery.barrier()` confirms that reset
        // has actually run — using `flushRaceHookForTesting`/
        // `raceTicketForTesting` rather than waiting on a real, sub-
        // microsecond production race.
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: false)
        defer {
            decoder.flushRaceHookForTesting = nil
            decoder.close()
        }

        for i in 0..<5 {
            let bl = try #require(Self.baseLayer())
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { deliveries.count == 5 }

        let racer = try #require(Self.baseLayer())
        decoder.flushRaceHookForTesting = { [weak decoder] in
            decoder?.raceTicketForTesting(buffer: racer, pts: Self.pts(5))
        }

        decoder.flush()

        // The raced ticket must have been delivered exactly once — not
        // dropped as stale-epoch, and not left stalled
        // behind a hole that never fills.
        try await waitFor { deliveries.count == 6 }
        let got = deliveries.snapshot
        let late = got.filter { CMTimeCompare($0.pts, Self.pts(5)) == 0 }
        #expect(late.count == 1, "the ticket raced into the unlock-to-barrier gap must be delivered exactly once, not dropped")
        #expect(Self.isStrictlyIncreasing(got))
    }
    #endif

    /// A packet carrying in-band parameter sets and one (garbage) slice, as `decode(packet:)` sees it.
    private static func inBandPacket(pts: Int64) throws -> UnsafeMutablePointer<AVPacket> {
        let slice = hevcNAL(type: 1, payload: [0x11, 0x22, 0x33, 0x44])
        return try #require(makeAvccPacket([hevcVPS, hevcSPS, hevcPPS, slice], pts: pts))
    }

    #if DEBUG
    @Test("a post-seek packet fed with the new epoch between the dual epoch bump and the sub-decoder flush reaches VideoToolbox; a pre-seek one does not")
    func postSeekPacketInTheFlushWindowIsNotDropped() async throws {
        // The host feeds from the demux thread while a seek's flush() runs. It reads the new epoch the
        // moment flush() publishes it. The sub-decoders used to move only in their own flush(), later,
        // so a packet fed in this window passed the dual gate and was refused by a decoder still on
        // the old epoch: the post-seek IRAP never reached VideoToolbox.
        let primary = HardwareVideoDecoder()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer(), primaryDecoder: primary, enhancementDecoder: nil)
        decoder.onFrame = { _, _, _ in }
        defer { decoder.flushWillTakeLifecycleLockHookForTesting = nil; decoder.flushRaceHookForTesting = nil; decoder.close() }
        let submitted = LockedCounter()
        primary.onSubmittedToVideoToolboxForTesting = { submitted.increment() }

        // The first packet opens the primary decoder from its in-band parameter sets.
        let pre = try Self.inBandPacket(pts: 0)
        defer { var p: UnsafeMutablePointer<AVPacket>? = pre; trackedPacketFree(&p) }
        decoder.decode(packet: pre, epoch: decoder.feedEpoch)
        if decoder.fatalDecodeError != nil { try Test.cancel("hardware HEVC session unavailable: \(decoder.fatalDecodeError!)") }
        #expect(submitted.value == 1)
        let oldEpoch = decoder.feedEpoch

        let post = try Self.inBandPacket(pts: 90000)
        defer { var p: UnsafeMutablePointer<AVPacket>? = post; trackedPacketFree(&p) }
        let submittedInWindow = LockedCounter()
        decoder.flushRaceHookForTesting = {
            // flush() has published the new epoch and not yet touched the sub-decoders.
            decoder.decode(packet: post, epoch: decoder.feedEpoch)
            submittedInWindow.set(submitted.value)
        }
        decoder.flush()
        #expect(decoder.feedEpoch == oldEpoch + 1)
        #expect(primary.feedEpoch == oldEpoch + 1, "the sub-decoder's own flush must not move the epoch a second time")
        #expect(submittedInWindow.value == 2, "the post-seek packet fed inside the window never reached VideoToolbox")

        // DEC-4: a packet decided under the old epoch must not enter VideoToolbox after the flush.
        decoder.decode(packet: pre, epoch: oldEpoch)
        #expect(submitted.value == 2)
        // And the epoch the host would read next is accepted.
        decoder.decode(packet: post, epoch: decoder.feedEpoch)
        #expect(submitted.value == 3)
    }
    #endif

    /// Fake whose in-band open always fails.
    private final class FailingOpenFakeDecoder: SingleLayerVideoDecoder, @unchecked Sendable {
        private let lock = NSLock()
        private var _opens = 0, _decodes = 0
        var openCount: Int { lock.lock(); defer { lock.unlock() }; return _opens }
        var decodeCount: Int { lock.lock(); defer { lock.unlock() }; return _decodes }
        struct OpenFailed: Error {}
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        var feedEpoch: UInt64 = 0
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {}
        func open(parameterSets: [[UInt8]], timeBase: AVRational, onFrame: @escaping DecodedFrameHandler) throws {
            lock.lock(); _opens += 1; lock.unlock()
            throw OpenFailed()
        }
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) { lock.lock(); _decodes += 1; lock.unlock() }
        func flush() {}
        func close() {}
    }

    @Test("an in-band primary open that fails is reported once and not retried on every later packet")
    func failedInBandOpenFailsOnce() throws {
        let primary = FailingOpenFakeDecoder()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer(), primaryDecoder: primary, enhancementDecoder: nil)
        defer { decoder.close() }
        let reported = LockedCounter()
        decoder.onFatalDecodeError = { _ in reported.increment() }
        let lines = LockedCounter()
        let previous = EngineLog.handler
        EngineLog.handler = { line in if line.contains("failed to open the primary decoder") { lines.increment() } }
        defer { EngineLog.handler = previous }

        for i in 0..<5 {
            let pkt = try Self.inBandPacket(pts: Int64(i) * 3000)
            decoder.decode(packet: pkt)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        #expect(primary.openCount == 1, "the open was retried on a later packet")
        #expect(reported.value == 1)
        #expect(lines.value == 1)
        #expect(decoder.fatalDecodeError is FailingOpenFakeDecoder.OpenFailed)
        #expect(primary.decodeCount == 0)
    }

    @Test("an enhancement decoder that fails to open is logged once and not retried on every later packet")
    func failedEnhancementOpenFailsOnce() throws {
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer(), primaryDecoder: FailingOpenFakeDecoder(), enhancementDecoder: nil)
        let enhancement = FailingOpenFakeDecoder()
        let built = LockedCounter()
        decoder.makeEnhancementDecoder = { built.increment(); return enhancement }
        defer { decoder.close() }
        let lines = LockedCounter()
        let previous = EngineLog.handler
        EngineLog.handler = { line in if line.contains("failed to initialize EL decoder") { lines.increment() } }
        defer { EngineLog.handler = previous }

        for i in 0..<5 {
            let pkt = try Self.inBandPacket(pts: Int64(i) * 3000)
            decoder.ensureEnhancementDecoder(from: pkt)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        #expect(enhancement.openCount == 1, "the open was retried on a later packet")
        #expect(built.value == 1, "a new session was built for a later packet")
        #expect(lines.value == 1)
        #expect(decoder.enhancementDecoderOpenError is FailingOpenFakeDecoder.OpenFailed)
        #expect(decoder.fatalDecodeError == nil, "a missing enhancement layer leaves the base layer to show")
        // close() starts the next session clean.
        decoder.close()
        #expect(decoder.enhancementDecoderOpenError == nil)
    }

    @Test("the alignment's restamp bound is what the pairing skew bound can absorb")
    func alignmentBoundTracksSkewBound() {
        #expect(DualLayerVideoDecoder.makeAlignment().maxBackwardRestamp == DualLayerVideoDecoder.maxLayerSkewFrames - 1)
    }

    @Test("a crafted raw timestamp that overflows the time-base product yields no key instead of trapping")
    func canonicalKeyIsOverflowSafe() {
        let tb = AVRational(num: 1, den: 90000)
        #expect(DualLayerVideoDecoder.canonicalKey(rawPTS: 90000, timeBase: tb) == 90000)
        #expect(DualLayerVideoDecoder.canonicalKey(rawPTS: Int64.min, timeBase: tb) == Int64.min)
        let wide = AVRational(num: 1_000_000, den: 1)
        #expect(DualLayerVideoDecoder.canonicalKey(rawPTS: Int64.max, timeBase: wide) == Int64.min)
        #expect(DualLayerVideoDecoder.canonicalKey(rawPTS: Int64.min + 1, timeBase: wide) == Int64.min)
        // Large but representable products saturate in CoreMedia rather than trapping.
        _ = DualLayerVideoDecoder.canonicalKey(rawPTS: Int64.max / 2, timeBase: AVRational(num: 2, den: 1))
    }

    @Test("a slow onFrame does not block pairing or flush() behind the decoder lock",
          .timeLimit(.minutes(5)))
    func slowOnFrameDoesNotBlockDecoderOperations() async throws {
        // The old `deliver()` took the decoder's lock and called `emit` (hence
        // `onFrame`) from inside it, so a slow host callback would have stalled
        // every later frame handler and `flush()` behind the same lock. With
        // `OrderedDelivery` owning `emit` on its own queue, pairing a new frame
        // never waits on `onFrame` at all — but `flush()` is a different claim:
        // its `orderedDelivery.barrier()` call legitimately waits for whatever
        // `emit` is currently in the middle of before draining can proceed. The
        // bound here is "as long as `onFrame` itself takes", not "instantly"
        // and not "forever".
        // `firstCallStarted` is polled rather than waited on with a semaphore:
        // `DispatchSemaphore.wait` is unavailable from this `async` test body
        // (it would block the cooperative thread pool), but it is exactly
        // right *inside* the plain, non-async `onFrame` closure below, which
        // runs on `OrderedDelivery`'s own queue and is what this test needs
        // to hold still to prove pairing is not waiting on it.
        let firstCallStarted = BoolFlag()
        let releaseFirstCall = DispatchSemaphore(value: 0)
        let callCount = LockedCounter()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        decoder.onFrame = { buffer, pts, hdr10 in
            let isFirst = callCount.incrementAndCheckFirst()
            if isFirst {
                firstCallStarted.set()
                releaseFirstCall.wait()
            }
            deliveries.record(buffer, pts, hdr10)
        }
        decoder.primeForTesting(enhancementLayer: false)
        defer {
            releaseFirstCall.signal() // in case an assertion below fails first
            decoder.close()
        }

        let bl0 = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(0), hdr10Data: nil)
        try await waitFor { firstCallStarted.isSet }
        #expect(firstCallStarted.isSet, "onFrame for frame 0 never started")

        // While that first `onFrame` call is still parked, pairing a new frame
        // must not wait on it at all: `handleBaseLayerFrame` only ever
        // `fulfil`s a ticket onto `OrderedDelivery`'s queue (`queue.async`,
        // non-blocking) and never calls into `emit`. The call returning at all,
        // with the release semaphore still unsignalled, is the proof: if it
        // waited on the parked `onFrame` it would never return and the test's
        // time limit would report it. No wall-clock threshold is involved.
        let bl1 = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: bl1, pts: Self.pts(1), hdr10Data: nil)

        // `flush()` legitimately waits for the in-flight `emit` (its `barrier()`
        // waits on the queue `emit` runs on), so it runs on a thread of its own
        // and the release is signalled from here. It must then finish; if the
        // decoder's lock were held across the wait it would hang, and the time
        // limit would say so.
        let flushDone = BoolFlag()
        Thread.detachNewThread {
            decoder.flush()
            flushDone.set()
        }
        releaseFirstCall.signal()
        try await waitFor { flushDone.isSet }
        #expect(flushDone.isSet, "flush() never returned after the slow onFrame call was released")

        decoder.quiesceForTesting()
    }

    /// Thread-safe increment that also reports whether this call was the
    /// first one, without a data race between the check and the increment.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func incrementAndCheckFirst() -> Bool {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count == 1
        }
        func increment() { lock.lock(); count += 1; lock.unlock() }
        func set(_ v: Int) { lock.lock(); count = v; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A boolean settable from one thread and polled from another, with no
    /// torn reads. Used both as a "stop requested" flag and, in
    /// `slowOnFrameDoesNotBlockDecoderOperations`, as a "started" flag — the
    /// name is generic on purpose.
    private final class BoolFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Lock-protected "flushes started"/"flushes returned" counters for the
    /// per-flush I3 detector in `flushFromAnotherThreadInATightLoopKeepsInvariantI3`.
    private final class FlushCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var returned = 0
        /// Call immediately before `decoder.flush()`. Returns the new count.
        @discardableResult
        func beginFlush() -> Int { lock.lock(); started += 1; defer { lock.unlock() }; return started }
        /// Call immediately after `decoder.flush()` returns.
        func endFlush() { lock.lock(); returned += 1; lock.unlock() }
        var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }
        var returnedCount: Int { lock.lock(); defer { lock.unlock() }; return returned }
    }

    /// Records each frame's "started" tag (keyed by its unique PTS value) and
    /// any I3 violation the detector in
    /// `flushFromAnotherThreadInATightLoopKeepsInvariantI3` finds — a class,
    /// like `Deliveries`/`FlushCounters` above, so the producer task and the
    /// `onFrame` closure can share it as a `let` capture rather than a `var`
    /// one, which Swift 6 strict concurrency refuses to let a closure and a
    /// detached task mutate directly.
    private final class ViolationTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var startedTagByPTS: [Int64: Int] = [:]
        private var violations: [String] = []

        /// Marks a frame as being inside its pairing call. Delivery is asynchronous and can run before
        /// the call returns, so the frame has to be known to the detector before the call starts; the
        /// real tag replaces this once the call returns.
        func registerInFlight(ptsValue: Int64) {
            lock.lock(); startedTagByPTS[ptsValue] = Self.inFlight; lock.unlock()
        }

        func recordStartedTag(_ tag: Int, forPTSValue ptsValue: Int64) {
            lock.lock(); startedTagByPTS[ptsValue] = tag; lock.unlock()
        }

        private static let inFlight = Int.max

        /// Checks one delivery against the rule and records a violation if
        /// found. Call from `onFrame`, passing the "returned" count read at
        /// that moment.
        func checkDelivery(ptsValue: Int64, returnedAtDelivery: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard let startedTag = startedTagByPTS[ptsValue] else {
                violations.append("pts=\(ptsValue) delivered with no tag registered")
                return
            }
            // Still inside its pairing call: it cannot have been paired before a flush that has since returned.
            guard startedTag != Self.inFlight, startedTag < returnedAtDelivery else { return }
            violations.append("pts=\(ptsValue) startedTag=\(startedTag) returnedAtDelivery=\(returnedAtDelivery)")
        }

        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return violations }
    }

    @Test("flushing from another thread in a tight loop, while frames keep arriving, never delivers a frame paired before flush k started after flush k returns (I3)")
    func flushFromAnotherThreadInATightLoopKeepsInvariantI3() async throws {
        // An elapsed-time bound and the epoch bump cannot detect an I3
        // violation, and neither can `isStrictlyIncreasing` alone: a pre-flush
        // frame delivered late still carries a lower PTS than every post-flush
        // frame the ever-increasing producer goes on to emit.
        //
        // So this test uses a per-flush detector: two lock-protected counters, "flushes started" and
        // "flushes returned". Each frame is tagged, the instant its pairing
        // call returns, with the "started" count at that moment — how many
        // flushes had already been kicked off by the time this frame took
        // its ticket. Each delivery reads the "returned" count at the moment
        // `onFrame` fires — how many flushes have already fully completed by
        // the time this frame reached the host. The rule: a frame whose
        // pairing call returned before flush k started (tag < k) must never
        // reach `onFrame` after flush k has returned (returnedAtDelivery >=
        // k). Collapsing "there exists such a k" to a single per-frame
        // comparison is valid because the tightest possible k for any
        // violation is the number of flushes already returned at delivery
        // time itself: if `tag < returnedAtDelivery`, then k =
        // returnedAtDelivery satisfies `tag < k` and `k <= returnedAtDelivery`
        // simultaneously, which is exactly the violation shape.
        let counters = FlushCounters()
        let tracker = ViolationTracker()

        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        decoder.onFrame = { buffer, pts, hdr10 in
            let returnedAtDelivery = counters.returnedCount
            tracker.checkDelivery(ptsValue: pts.value, returnedAtDelivery: returnedAtDelivery)
            deliveries.record(buffer, pts, hdr10)
        }
        decoder.primeForTesting(enhancementLayer: false)
        defer { decoder.close() }

        let stop = BoolFlag()

        let producing = BlockingWork.detached { () -> Void in
            var i: Int64 = 0
            while !stop.isSet {
                if let bl = Self.baseLayer() {
                    let pts = Self.pts(i)
                    tracker.registerInFlight(ptsValue: pts.value)
                    decoder.handleBaseLayerFrame(baseBuffer: bl, pts: pts, hdr10Data: nil)
                    // The real tag is taken AFTER the handler returns, matching the detector's rule.
                    let tag = counters.startedCount
                    tracker.recordStartedTag(tag, forPTSValue: pts.value)
                }
                i += 1
            }
        }

        // Flush back-to-back, on another thread, for as long as the producer
        // above keeps feeding frames concurrently. Each call must still
        // return promptly (proving no deadlock under contention) and bump the
        // feed epoch (proving it actually ran, not a silent no-op).
        for _ in 0..<200 {
            counters.beginFlush()
            let epochBefore = decoder.feedEpoch
            // A deadlock under producer load shows as this loop never finishing, which the suite's
            // time limit reports; a wall-clock bound per flush would only add scheduler noise.
            decoder.flush()
            counters.endFlush()
            #expect(decoder.feedEpoch == epochBefore + 1)
        }

        stop.set()
        await producing.value
        decoder.quiesceForTesting()

        let finalViolations = tracker.snapshot
        #expect(finalViolations.isEmpty, "I3 violated: \(finalViolations.prefix(5))")

        // Order is still a real property worth keeping, just not the one
        // that actually proves I3 (see the comment above): any I3 violation
        // this detector doesn't already flag would have to slip a stale
        // frame in without disturbing PTS order at all, which the pairing
        // ticket order already makes exceedingly unlikely — but it costs
        // nothing extra to keep checking.
        #expect(Self.isStrictlyIncreasing(deliveries.snapshot))
    }

    // MARK: - Known defects

    @Test("a pruned base-layer frame cannot be delivered after a newer composed frame", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func prunedFrameDoesNotOvertakeNewerFrames() async throws {
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }

        // Frame 0's enhancement layer is lost, so it waits in the base-layer queue.
        let orphan = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: orphan, pts: Self.pts(0), hdr10Data: nil)
        // Frame 1 pairs immediately and is composed.
        let bl1 = try #require(Self.baseLayer())
        let el1 = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el1, pts: Self.pts(1))
        decoder.handleBaseLayerFrame(baseBuffer: bl1, pts: Self.pts(1), hdr10Data: nil)
        // More orphans until frame 0 is pushed out of the queue.
        var next: Int64 = 2
        while !deliveries.snapshot.contains(where: { $0.buffer === orphan }) && next < 60 {
            let bl = try #require(Self.baseLayer())
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(next), hdr10Data: nil)
            next += 1
        }
        try await waitFor { deliveries.snapshot.contains { $0.buffer !== orphan && CMTimeCompare($0.pts, Self.pts(1)) == 0 } }

        let got = deliveries.snapshot
        #expect(Self.isStrictlyIncreasing(got))
    }

    @Test("a lost enhancement layer delays its base layer by at most K frames, in order")
    func lostEnhancementLayerDelaysBaseLayerByAtMostKFrames() async throws {
        // Synchronous composer, so delivery is synchronous and the bound is exact:
        // frame 0 waits while newer pairs settle, then goes out under its own
        // (oldest) ticket once K newer base-layer frames have arrived.
        let k = DualLayerVideoDecoder.maxLayerSkewFrames
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        defer { decoder.close() }

        // Not `deliveries.count == 0`: delivery is always one more
        // `queue.async` hop away, so it would read 0 whether or not frame 0
        // was still held back. `blQueueCount` is synchronous and
        // deterministic: `collectDueBypasses` runs entirely under `lock`
        // inside `handleBaseLayerFrame`, so by the time that call returns,
        // frame 0 is provably still queued (not yet bypassed) if and only
        // if fewer than K newer base-layer frames have arrived.
        let orphan = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: orphan, pts: Self.pts(0), hdr10Data: nil)
        #expect(decoder.stateSnapshotForTesting.blQueueCount == 1, "a base-layer frame with a pending enhancement layer must wait for it")

        for i in 1..<k {
            let bl = try #require(Self.baseLayer())
            let el = try #require(Self.enhancementLayer())
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        #expect(decoder.stateSnapshotForTesting.blQueueCount == 1, "only \(k - 1) newer frames have arrived; frame 0 must still wait")

        let blK = try #require(Self.baseLayer())
        let elK = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(Int64(k)), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: elK, pts: Self.pts(Int64(k)))
        decoder.handleBaseLayerFrame(baseBuffer: blK, pts: Self.pts(Int64(k)), hdr10Data: nil)

        // Releasing frame 0 (and composing frame k) both still end in
        // a `queue.async` hop through `OrderedDelivery`, so give it a chance
        // to drain before reading the final snapshot.
        try await waitFor { deliveries.count == k + 1 }
        let got = deliveries.snapshot
        #expect(got.count == k + 1, "the Kth newer frame must release frame 0")
        #expect(got.first?.buffer === orphan, "frame 0 kept its arrival ticket, so it goes out first")
        #expect(Self.isStrictlyIncreasing(got))
    }

    @Test("HDR10+ side data survives whichever layer arrives last", .enabled(if: Self.metalAvailable, "needs a Metal device"))
    func hdr10SideDataSurvivesArrivalOrder() async throws {
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        let deliveries = Deliveries()
        let decoder = Self.decoder(recordingInto: deliveries, enhancementLayer: true)
        defer { decoder.close() }
        let side = Data([0xB5, 0x00, 0x3C])

        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(1), hdr10Data: side)
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(1))

        try await waitFor { deliveries.count == 1 }
        let got = deliveries.snapshot.first?.hdr10
        #expect(got == side)
    }

    // MARK: - Composer unavailable

    @Test("with no composer, EL decoder is never engaged and base layer is delivered")
    func noComposerDisablesEnhancementLayerAndDeliversBaseLayer() async throws {
        // Inject nil composer via internal initializer (bypasses open() which would throw).
        let primary = CountingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: nil,
            primaryDecoder: primary,
            enhancementDecoder: nil
        )
        let deliveries = Deliveries()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        // Prime as FEL stream (what classifyPacketResultForTesting would set after first RPU)
        decoder.primeStreamForTesting(.fel)
        defer { decoder.close() }

        // Even though stream is classified FEL, no composer → no EL engagement
        #expect(decoder.engagesEnhancementLayerForTesting() == false, "no composer must disable EL engagement")
        #expect(decoder.stateSnapshotForTesting.enhancementEngaged == false)

        // Simulate a FEL packet: EL packet would be freed, not fed to any decoder
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)

        // EL arrives first - should be queued but never paired because no EL decoder exists
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(1))
        // BL arrives - should bypass and deliver immediately (no composition possible)
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(1), hdr10Data: nil)

        try await waitFor { deliveries.count == 1 }
        let got = deliveries.snapshot.first
        #expect(got != nil, "base layer must be delivered")
        #expect(got?.buffer === bl, "delivered buffer must be the base layer (bypass)")
        #expect(CMTimeCompare(got?.pts ?? .invalid, Self.pts(1)) == 0)

        // Primary decoder never received the EL packet (it doesn't exist), but BL was fed
        // Note: primary.decodeCount would be 0 because we bypassed decode(packet:) and called handlers directly
        // The key assertion is that no enhancement decoder was created/engaged.
    }

    // MARK: - HardwareVideoDecoder.CustomBlockSource Lifecycle

    @Test("CustomBlockSource holds av_buffer_ref and unrefs idempotently")
    func customBlockSourceLifecycle() throws {
        guard let buf = av_buffer_alloc(256) else {
            Issue.record("Failed to allocate AVBuffer")
            return
        }
        var bufRef: UnsafeMutablePointer<AVBufferRef>? = buf
        defer {
            if bufRef != nil {
                av_buffer_unref(&bufRef)
            }
        }

        #expect(av_buffer_get_ref_count(buf) == 1)

        do {
            let source = try #require(HardwareVideoDecoder.CustomBlockSource(buf: buf))
            #expect(av_buffer_get_ref_count(buf) == 2)
            #expect(source.dataPtr == UnsafeMutableRawPointer(buf.pointee.data!))

            // Test idempotent releaseBuffer
            source.releaseBuffer()
            #expect(av_buffer_get_ref_count(buf) == 1)
            #expect(source.avBuf == nil)

            // Second releaseBuffer call is a no-op (idempotent, no double-unref)
            source.releaseBuffer()
            #expect(av_buffer_get_ref_count(buf) == 1)
        }
        // After deinit of source, refcount stays 1 (no double-unref)
        #expect(av_buffer_get_ref_count(buf) == 1)
    }

    @Test("CustomBlockSource addresses the packet payload, not buf->data, when they differ (Matroska packets sit at +4)")
    func customBlockSourceHonoursPacketDataOffset() throws {
        let buf = try #require(av_buffer_alloc(256))
        var bufRef: UnsafeMutablePointer<AVBufferRef>? = buf
        defer { av_buffer_unref(&bufRef) }

        let payload = try #require(buf.pointee.data).advanced(by: 4)
        let source = try #require(HardwareVideoDecoder.CustomBlockSource(buf: buf, data: payload))
        #expect(source.dataPtr == UnsafeMutableRawPointer(payload))
        #expect(source.dataPtr != UnsafeMutableRawPointer(buf.pointee.data!))
        source.releaseBuffer()
    }

    @Test("CMBlockBuffer with CustomBlockSource holds av_buffer_ref and unrefs on deallocation")
    func cmBlockBufferWithCustomBlockSourceLifecycle() throws {
        guard let buf = av_buffer_alloc(512) else {
            Issue.record("Failed to allocate AVBuffer")
            return
        }
        var bufRef: UnsafeMutablePointer<AVBufferRef>? = buf
        defer {
            if bufRef != nil {
                av_buffer_unref(&bufRef)
            }
        }

        #expect(av_buffer_get_ref_count(buf) == 1)

        do {
            let size = 512
            let blockSource = try #require(HardwareVideoDecoder.CustomBlockSource(buf: buf))
            let (blockBuffer, status) = HardwareVideoDecoder.makeBlockBuffer(wrapping: blockSource, size: size)
            #expect(status == kCMBlockBufferNoErr)
            #expect(blockBuffer != nil)
            // Block buffer holds av_buffer_ref
            #expect(av_buffer_get_ref_count(buf) == 2)

            // Verify memory block pointer is accessible and matches buf data
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<CChar>?
            let accessStatus = CMBlockBufferGetDataPointer(
                blockBuffer!,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            #expect(accessStatus == kCMBlockBufferNoErr)
            #expect(totalLength == size)
            #expect(dataPointer == UnsafeMutablePointer<CChar>(OpaquePointer(buf.pointee.data)))
        }

        // CMBlockBuffer went out of scope: FreeBlock ran takeRetainedValue and unref'd avBuf
        #expect(av_buffer_get_ref_count(buf) == 1)
    }

    @Test("CustomBlockSource cleanup on CMBlockBuffer creation failure balances retain")
    func customBlockSourceCleanupOnCreationFailure() throws {
        guard let buf = av_buffer_alloc(256) else {
            Issue.record("Failed to allocate AVBuffer")
            return
        }
        var bufRef: UnsafeMutablePointer<AVBufferRef>? = buf
        defer {
            if bufRef != nil {
                av_buffer_unref(&bufRef)
            }
        }

        #expect(av_buffer_get_ref_count(buf) == 1)

        let blockSource = try #require(HardwareVideoDecoder.CustomBlockSource(buf: buf))
        // A payload longer than the block is refused by CoreMedia, which is the failure the decoder's
        // own wrapper has to clean up after.
        let (blockBuffer, status) = HardwareVideoDecoder.makeBlockBuffer(wrapping: blockSource, size: 256, dataLength: 512)
        #expect(status != kCMBlockBufferNoErr)
        #expect(blockBuffer == nil)

        // Retain count of AVBuffer drops back to 1 and blockSource is deallocated without leaking
        #expect(av_buffer_get_ref_count(buf) == 1)
    }

    // MARK: - HardwareVideoDecoder.decode with CustomBlockSource vs Fallback Copy

    private static let hevcVPS: [UInt8] = [
        0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00,
        0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0x95, 0x94, 0x09
    ]
    private static let hevcSPS: [UInt8] = [
        0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x11, 0x07,
        0xca, 0xd9, 0x65, 0x65, 0x4a, 0x4c, 0x2f, 0x01, 0x6a, 0x12, 0x20, 0x12,
        0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x00, 0xc0, 0x40
    ]
    private static let hevcPPS: [UInt8] = [
        0x44, 0x01, 0xc0, 0x73, 0xc1, 0x89
    ]

    @Test("CustomBlockSource failable initializer returns nil if data is nil")
    func customBlockSourceFailableInit() throws {
        guard let buf = av_buffer_alloc(64) else {
            Issue.record("Failed to allocate AVBuffer")
            return
        }
        var bufRef: UnsafeMutablePointer<AVBufferRef>? = buf
        defer {
            if bufRef != nil {
                av_buffer_unref(&bufRef)
            }
        }

        #expect(av_buffer_get_ref_count(buf) == 1)

        // Valid buffer succeeds
        let validSource = HardwareVideoDecoder.CustomBlockSource(buf: buf)
        #expect(validSource != nil)
        validSource?.releaseBuffer()
        #expect(av_buffer_get_ref_count(buf) == 1)

        // Buffer with nil data returns nil without leaking av_buffer_ref
        let originalData = buf.pointee.data
        buf.pointee.data = nil
        let nilSource = HardwareVideoDecoder.CustomBlockSource(buf: buf)
        #expect(nilSource == nil)
        #expect(av_buffer_get_ref_count(buf) == 1)
        buf.pointee.data = originalData
    }

    @Test("HardwareVideoDecoder.decode with useCustomBlockSource holds av_buffer_ref and decrements on release")
    func hardwareVideoDecoderHoldsAndDecrementsBufferRef() throws {
        let decoder = HardwareVideoDecoder()
        do {
            try decoder.open(
                parameterSets: [Self.hevcVPS, Self.hevcSPS, Self.hevcPPS],
                timeBase: AVRational(num: 1, den: 90000),
                onFrame: { _, _, _ in }
            )
        } catch {
            // Hardware HEVC decompression session might not be supported in some environments:
            // reported as skipped, not passed.
            try Test.cancel("hardware HEVC session creation failed: \(error)")
        }
        defer { decoder.close() }

        decoder.useCustomBlockSource = true

        guard let avBuf = av_buffer_alloc(64) else {
            Issue.record("Failed to allocate AVBuffer")
            return
        }
        var avBufRef: UnsafeMutablePointer<AVBufferRef>? = avBuf
        defer {
            if avBufRef != nil {
                av_buffer_unref(&avBufRef)
            }
        }

        // Initialize with a 4-byte length-prefixed NAL (SEI prefix)
        let dataPtr = avBuf.pointee.data!
        dataPtr[0] = 0; dataPtr[1] = 0; dataPtr[2] = 0; dataPtr[3] = 60
        dataPtr[4] = 0x4E; dataPtr[5] = 0x01
        for i in 6..<64 { dataPtr[i] = 0x80 }

        #expect(av_buffer_get_ref_count(avBuf) == 1)

        guard let packet = trackedPacketAlloc() else {
            Issue.record("Failed to allocate AVPacket")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        packet.pointee.buf = av_buffer_ref(avBuf)
        packet.pointee.data = avBuf.pointee.data
        packet.pointee.size = 64
        packet.pointee.pts = 0
        packet.pointee.dts = 0

        #expect(av_buffer_get_ref_count(avBuf) == 2)

        var refCountWhileHeld = 0
        var heldBlockBuffer: CMBlockBuffer?
        decoder.onBlockBufferAllocatedForTesting = { bb in
            refCountWhileHeld = Int(av_buffer_get_ref_count(avBuf))
            heldBlockBuffer = bb
        }

        decoder.decode(packet: packet)

        // CustomBlockSource took an av_buffer_ref when wrapping into CMBlockBuffer
        #expect(refCountWhileHeld >= 3)
        #expect(heldBlockBuffer != nil)

        // Release caller's packet reference
        av_buffer_unref(&packet.pointee.buf)
        // Still held by avBufRef and heldBlockBuffer's CustomBlockSource
        #expect(av_buffer_get_ref_count(avBuf) == 2)

        // Releasing the block buffer decrements the ref count back to 1
        heldBlockBuffer = nil
        #expect(av_buffer_get_ref_count(avBuf) == 1)

        // Flush and close decoder to release asynchronous frames and invalidate session
        decoder.flush()
        decoder.close()

        #expect(av_buffer_get_ref_count(avBuf) == 1)
    }

    @Test("HardwareVideoDecoder.decode falls back cleanly to copy when buf == nil")
    func hardwareVideoDecoderFallsBackToCopyWhenBufNil() throws {
        let decoder = HardwareVideoDecoder()
        do {
            try decoder.open(
                parameterSets: [Self.hevcVPS, Self.hevcSPS, Self.hevcPPS],
                timeBase: AVRational(num: 1, den: 90000),
                onFrame: { _, _, _ in }
            )
        } catch {
            try Test.cancel("hardware HEVC session creation failed: \(error)")
        }
        defer { decoder.close() }

        decoder.useCustomBlockSource = true

        let rawData = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer { rawData.deallocate() }
        rawData.initialize(repeating: 0x80, count: 64)
        rawData[0] = 0; rawData[1] = 0; rawData[2] = 0; rawData[3] = 60
        rawData[4] = 0x4E; rawData[5] = 0x01

        guard let packet = trackedPacketAlloc() else {
            Issue.record("Failed to allocate AVPacket")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        packet.pointee.buf = nil // Force fallback to copy path
        packet.pointee.data = rawData
        packet.pointee.size = 64
        packet.pointee.pts = 0
        packet.pointee.dts = 0

        // Must decode without crashing or throwing
        decoder.decode(packet: packet)

        decoder.flush()
        decoder.close()
    }

    // MARK: - DualLayerVideoDecoder Untouched Packet Delivery

    private static func makeAvccPacket(_ nals: [[UInt8]], pts: Int64 = 0) -> UnsafeMutablePointer<AVPacket>? {
        var total = 0
        for nal in nals { total += 4 + nal.count }
        guard let avBuf = av_buffer_alloc(total + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else { return nil }
        guard let dst = avBuf.pointee.data else {
            var b: UnsafeMutablePointer<AVBufferRef>? = avBuf
            av_buffer_unref(&b)
            return nil
        }
        var w = 0
        for nal in nals {
            let n = nal.count
            dst[w + 0] = UInt8((n >> 24) & 0xFF)
            dst[w + 1] = UInt8((n >> 16) & 0xFF)
            dst[w + 2] = UInt8((n >> 8) & 0xFF)
            dst[w + 3] = UInt8(n & 0xFF)
            w += 4
            nal.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(dst + w, base, n)
                }
            }
            w += n
        }
        memset(dst + total, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
        guard let pkt = trackedPacketAlloc() else {
            var b: UnsafeMutablePointer<AVBufferRef>? = avBuf
            av_buffer_unref(&b)
            return nil
        }
        pkt.pointee.buf = avBuf
        pkt.pointee.data = dst
        pkt.pointee.size = Int32(total)
        pkt.pointee.pts = pts
        pkt.pointee.dts = pts
        return pkt
    }

    private static func hevcNAL(type: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), 0x01] + payload
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            if let byte = UInt8(hex[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        return bytes
    }

    private static func makeMelRpuBytes() -> [UInt8] {
        let felBytes = Self.hexToBytes(DoviFelMathTests.clipARpuHex)
        guard let rpu = dovi_parse_unspec62_nalu(felBytes, felBytes.count) else { return [] }
        defer { dovi_rpu_free(rpu) }
        // libdovi returns a handle even when parsing fails; an error means there is nothing to convert.
        guard dovi_rpu_get_error(rpu) == nil else { return [] }
        _ = dovi_convert_rpu_with_mode(rpu, 1)
        guard let out = dovi_write_unspec62_nalu(rpu) else { return [] }
        defer { dovi_data_free(out) }
        return [UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))
    }

    @Test("DualLayerVideoDecoder leaves FEL packet untouched and extracts EL and RPU")
    func dualLayerVideoDecoderLeavesFELPacketUntouched() throws {
        let primary = CountingFakeDecoder()
        let enhancement = CountingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        defer { decoder.close() }

        let vps = Self.hevcNAL(type: 32, payload: [0x0c, 0x01, 0xff, 0xff])
        let sps = Self.hevcNAL(type: 33, payload: [0x01, 0x02, 0x20, 0x00])
        let pps = Self.hevcNAL(type: 34, payload: [0xc0, 0x73])
        let bl = Self.hevcNAL(type: 1, payload: [0x11, 0x22, 0x33, 0x44])
        let rpu = Self.hexToBytes(DoviFelMathTests.clipARpuHex)
        let el = Self.hevcNAL(type: 63, payload: [0x55, 0x66, 0x77, 0x88])

        guard let pkt = Self.makeAvccPacket([vps, sps, pps, bl, rpu, el], pts: 1000) else {
            Issue.record("Failed to build AVCC packet")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }

        let originalData = pkt.pointee.data
        let originalSize = pkt.pointee.size
        let originalBuf = pkt.pointee.buf

        decoder.decode(packet: pkt)

        // Packet pointer, size, and buffer must be COMPLETELY UNTOUCHED
        #expect(pkt.pointee.data == originalData)
        #expect(pkt.pointee.size == originalSize)
        #expect(pkt.pointee.buf == originalBuf)

        // Classified as FEL
        #expect(decoder.streamClassificationForTesting == .fel)

        // Primary received the base layer
        #expect(primary.decodeCount == 1)

        // Enhancement decoder was engaged and received the extracted EL packet
        #expect(enhancement.decodeCount == 1)

        // Display metadata RPU was extracted and cached
        #expect(decoder.stateSnapshotForTesting.dmRpuCacheCount == 1)
        // RPU params were extracted and cached
        #expect(decoder.stateSnapshotForTesting.rpuCacheCount == 1)
    }

    @Test("DualLayerVideoDecoder leaves MEL packet untouched and extracts RPU without engaging EL decoder")
    func dualLayerVideoDecoderLeavesMELPacketUntouched() throws {
        let primary = CountingFakeDecoder()
        let enhancement = CountingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        defer { decoder.close() }

        let vps = Self.hevcNAL(type: 32, payload: [0x0c, 0x01, 0xff, 0xff])
        let sps = Self.hevcNAL(type: 33, payload: [0x01, 0x02, 0x20, 0x00])
        let pps = Self.hevcNAL(type: 34, payload: [0xc0, 0x73])
        let bl = Self.hevcNAL(type: 1, payload: [0x11, 0x22, 0x33, 0x44])
        let melRpu = Self.makeMelRpuBytes()
        #expect(!melRpu.isEmpty)
        let el = Self.hevcNAL(type: 63, payload: [0x55, 0x66])

        guard let pkt = Self.makeAvccPacket([vps, sps, pps, bl, melRpu, el], pts: 2000) else {
            Issue.record("Failed to build AVCC packet")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }

        let originalData = pkt.pointee.data
        let originalSize = pkt.pointee.size
        let originalBuf = pkt.pointee.buf

        decoder.decode(packet: pkt)

        // Base-layer packet pointer, size, and buffer must be COMPLETELY UNTOUCHED
        #expect(pkt.pointee.data == originalData)
        #expect(pkt.pointee.size == originalSize)
        #expect(pkt.pointee.buf == originalBuf)

        // Classified as MEL
        #expect(decoder.streamClassificationForTesting == .mel)

        // Primary received the base layer
        #expect(primary.decodeCount == 1)

        // Enhancement decoder was NOT engaged for MEL
        #expect(enhancement.decodeCount == 0)

        // Display metadata RPU was extracted and cached
        #expect(decoder.stateSnapshotForTesting.dmRpuCacheCount == 1)
    }

    // MARK: - Per-Frame Logging & 1 Hz Summary

    @Test("per-frame logs (queue, bypass, drop) are NOT emitted at default info level")
    func fel14PerFrameLogsNotEmittedAtDefaultInfoLevel() throws {
        let prevHandler = EngineLog.handler
        defer { EngineLog.handler = prevHandler }

        var emittedLines: [String] = []
        let logLock = NSLock()
        EngineLog.handler = { line in
            logLock.lock()
            emittedLines.append(line)
            logLock.unlock()
        }

        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        defer { decoder.close() }

        // Send a base-layer frame with no EL / no RPU (will bypass)
        let buf1 = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: buf1, pts: Self.pts(1), hdr10Data: nil)

        // Simulate FEL stream with EL decoder active:
        decoder.primeForTesting(enhancementLayer: true)

        // Send unmatched BL (will queue BL)
        let buf2 = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: buf2, pts: Self.pts(2), hdr10Data: nil)

        // Send unmatched EL (will queue EL)
        let buf3 = try #require(Self.enhancementLayer())
        decoder.handleEnhancementLayerFrame(elBuffer: buf3, pts: Self.pts(3))

        logLock.lock()
        let captured = emittedLines
        logLock.unlock()

        let forbiddenPrefixes = [
            "[DualLayerVideoDecoder] queued base layer",
            "[DualLayerVideoDecoder] queued enhancement layer",
            "[DualLayerVideoDecoder] bypass,",
            "[DualLayerVideoDecoder] dropped stale enhancement layer",
            "[DualLayerVideoDecoder] pruned enhancement layer",
            "[DualLayerVideoDecoder] compose failed"
        ]
        for prefix in forbiddenPrefixes {
            let found = captured.filter { $0.contains(prefix) }
            #expect(found.isEmpty, "Found forbidden per-frame log at info level: \(found)")
        }
    }

    @Test("1 Hz summary aggregates and emits expected fields, then resets interval")
    func fel14OneHzSummaryAggregationAndFormat() throws {
        var summaryLines: [String] = []
        let logLock = NSLock()
        var summaryLevels: [EngineLog.Level] = []
        let composer = ImmediateFakeComposer()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }

        var currentTime: TimeInterval = 10.0
        decoder.summaryTimestampProviderForTesting = { currentTime }
        decoder.summarySinkForTesting = { line, level in
            logLock.lock()
            summaryLines.append(line)
            summaryLevels.append(level)
            logLock.unlock()
        }

        decoder.primeForTesting(enhancementLayer: true)

        let baseBuf = try #require(Self.baseLayer())
        let elBuf = try #require(Self.enhancementLayer())

        // Inject cached RPU and pair a frame at t = 10.0
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)

        // Base layer arrives at t = 10.0: sets lastSummaryTimestamp = 10.0
        decoder.handleBaseLayerFrame(baseBuffer: baseBuf, pts: Self.pts(1), hdr10Data: nil)

        // Enhancement layer arrives at t = 10.0: pairs and composes
        decoder.handleEnhancementLayerFrame(elBuffer: elBuf, pts: Self.pts(1))

        // Advance by 0.5s to 10.5: interval (1.0s) has not elapsed yet
        currentTime = 10.5
        decoder.maybeEmitSummary()
        logLock.lock()
        #expect(summaryLines.isEmpty)
        logLock.unlock()

        // Advance by 1.1s to 11.1 (currentTime >= 10.0 + 1.0): summary emits!
        currentTime = 11.1
        decoder.maybeEmitSummary()
        logLock.lock()
        #expect(summaryLines.count == 1)
        let summary = summaryLines.first ?? ""
        logLock.unlock()

        #expect(summary.contains("[DualLayerVideoDecoder] summary:"))
        #expect(summary.contains("composed=1"))
        #expect(summary.contains("bypassNoEL=0"))
        #expect(summary.contains("bypassNoRPU=0"))
        #expect(summary.contains("staleELDropped=0"))
        #expect(summary.contains("peakGpuSlots="))
        #expect(summary.contains("poolBuffers="))
        #expect(summary.contains("deliveryPendingPeak="))
        #expect(summary.contains("meanGpuMs="))
        // A healthy second is a trace: verbose reaches OSLog's debug level only, never the host handler.
        logLock.lock()
        #expect(summaryLevels == [.verbose])
        logLock.unlock()

        // Next call immediately at 11.2 does not emit again until another second passes
        currentTime = 11.2
        decoder.maybeEmitSummary()
        logLock.lock()
        #expect(summaryLines.count == 1)
        logLock.unlock()

        // After another 1.0s at 12.2, emits interval 2 with composed=0
        currentTime = 12.2
        decoder.maybeEmitSummary()
        logLock.lock()
        #expect(summaryLines.count == 2)
        let summary2 = summaryLines.last ?? ""
        logLock.unlock()
        #expect(summary2.contains("composed=0"))
    }

    @Test("a 1 Hz summary that counts a compose failure goes out at the default level")
    func summaryWithComposeFailureIsInfo() throws {
        var levels: [EngineLog.Level] = []
        var lines: [String] = []
        let logLock = NSLock()
        let decoder = DualLayerVideoDecoder(composer: FailingFakeComposer())
        defer { decoder.close() }

        var currentTime: TimeInterval = 30.0
        decoder.summaryTimestampProviderForTesting = { currentTime }
        decoder.summarySinkForTesting = { line, level in
            logLock.lock()
            lines.append(line)
            levels.append(level)
            logLock.unlock()
        }
        decoder.primeForTesting(enhancementLayer: true)

        let baseBuf = try #require(Self.baseLayer())
        let elBuf = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleBaseLayerFrame(baseBuffer: baseBuf, pts: Self.pts(1), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: elBuf, pts: Self.pts(1))

        currentTime = 31.1
        decoder.maybeEmitSummary()
        currentTime = 32.2
        decoder.maybeEmitSummary()

        logLock.lock()
        defer { logLock.unlock() }
        #expect(lines.count == 2)
        #expect(lines.first?.contains("composeFailures=1") == true)
        #expect(levels == [.info, .verbose], "only the interval with the failure reaches the host handler")
    }

    @Test("flush and close reset 1 Hz summary counters")
    func fel14FlushAndCloseResetSummaryCounters() throws {
        var summaryLines: [String] = []
        let logLock = NSLock()

        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        defer { decoder.close() }

        var currentTime: TimeInterval = 20.0
        decoder.summaryTimestampProviderForTesting = { currentTime }
        decoder.summarySinkForTesting = { line, _ in
            logLock.lock()
            summaryLines.append(line)
            logLock.unlock()
        }
        decoder.primeForTesting(enhancementLayer: true)

        let baseBuf = try #require(Self.baseLayer())
        let elBuf = try #require(Self.enhancementLayer())
        decoder.seedRPUForTesting(pts: Self.pts(1), params: Self.params(), displayMetadataNAL: nil)
        decoder.handleBaseLayerFrame(baseBuffer: baseBuf, pts: Self.pts(1), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: elBuf, pts: Self.pts(1))

        // Flush resets counters and timestamp
        decoder.flush()

        // Advance time to 21.5 and call maybeEmitSummary: since flush reset lastSummaryTimestamp to 0,
        // this call merely records the new baseline and does NOT emit
        currentTime = 21.5
        decoder.maybeEmitSummary()

        logLock.lock()
        #expect(summaryLines.isEmpty)
        logLock.unlock()

        // Advance by 1.1s to 22.6: summary emits with 0 composed frames
        currentTime = 22.6
        decoder.maybeEmitSummary()

        logLock.lock()
        #expect(summaryLines.count == 1)
        let summary = summaryLines.first ?? ""
        logLock.unlock()
        #expect(summary.contains("composed=0"))
    }

    // MARK: - Memory Limits & Queue Bounds

    @Test("output pool enforces its allocation threshold")
    func fel18OutputPoolEnforcesAllocationThreshold() throws {
        guard let composer = DoviFelComposer() else {
            Issue.record("Failed to create DoviFelComposer")
            return
        }
        guard let pool = composer.ensurePoolForTesting(width: 256, height: 256) else {
            Issue.record("Failed to create pixel buffer pool")
            return
        }

        var heldBuffers: [CVPixelBuffer] = []
        // Allocate up to the threshold
        for _ in 0..<DoviFelComposer.outputPoolAllocationThreshold {
            let res = composer.createOutputBufferForTesting(pool: pool)
            #expect(res.status == kCVReturnSuccess)
            if let buf = res.buffer { heldBuffers.append(buf) }
        }
        #expect(heldBuffers.count == DoviFelComposer.outputPoolAllocationThreshold)

        // 6th allocation exceeds the allocation threshold
        let excessRes = composer.createOutputBufferForTesting(pool: pool)
        #expect(excessRes.status == kCVReturnWouldExceedAllocationThreshold)
        #expect(excessRes.buffer == nil)

        // Release one buffer back to the pool
        heldBuffers.removeFirst()

        // Now allocation succeeds again
        let retryRes = composer.createOutputBufferForTesting(pool: pool)
        #expect(retryRes.status == kCVReturnSuccess)
        #expect(retryRes.buffer != nil)
    }

    @Test("P2: past the threshold the pool grows into a bounded reserve instead of refusing")
    func outputPoolReserveIsBounded() throws {
        let composer = try #require(DoviFelComposer())
        let pool = try #require(composer.ensurePoolForTesting(width: 256, height: 256))
        var held: [CVPixelBuffer] = []
        for _ in 0..<DoviFelComposer.outputPoolAllocationThreshold {
            held.append(try #require(composer.createOutputBufferForTesting(pool: pool).buffer))
        }
        #expect(composer.createOutputBufferForTesting(pool: pool).status == kCVReturnWouldExceedAllocationThreshold)
        for _ in 0..<DoviFelComposer.outputPoolReserve {
            let res = composer.createOutputBufferForTesting(pool: pool, reserve: true)
            #expect(res.status == kCVReturnSuccess)
            if let b = res.buffer { held.append(b) }
        }
        #expect(held.count == DoviFelComposer.outputPoolAllocationThreshold + DoviFelComposer.outputPoolReserve)
        // The reserve is a hard limit too.
        #expect(composer.createOutputBufferForTesting(pool: pool, reserve: true).status == kCVReturnWouldExceedAllocationThreshold)
        // Once the burst drains, the pool hands the buffers back out without allocating.
        held.removeLast(DoviFelComposer.outputPoolReserve + 1)
        #expect(composer.createOutputBufferForTesting(pool: pool).status == kCVReturnSuccess)
    }

    @Test("a seek flush keeps the output pool, so buffers the renderer still holds count against the same threshold")
    func flushKeepsOutputPool() throws {
        let composer = try #require(DoviFelComposer())
        let pool = try #require(composer.ensurePoolForTesting(width: 256, height: 256))
        var held: [CVPixelBuffer] = []
        for _ in 0..<DoviFelComposer.outputPoolAllocationThreshold {
            held.append(try #require(composer.createOutputBufferForTesting(pool: pool).buffer))
        }
        composer.flush()
        // Same pool object: a replacement would hand out a second threshold's worth on top of `held`,
        // the transient footprint doubling a seek used to cost.
        let after = try #require(composer.ensurePoolForTesting(width: 256, height: 256))
        #expect(after === pool)
        #expect(composer.createOutputBufferForTesting(pool: after).status == kCVReturnWouldExceedAllocationThreshold)
        held.removeFirst()
        #expect(composer.createOutputBufferForTesting(pool: after).status == kCVReturnSuccess)
        // Teardown does drop it, and no pool is built after it.
        composer.releaseOutputPool()
        #expect(composer.ensurePoolForTesting(width: 256, height: 256) == nil)
    }

    @Test("base-layer and enhancement-layer queues are strictly bounded at their own caps")
    func fel18QueuesBoundedAtK() throws {
        let decoder = DualLayerVideoDecoder(composer: ImmediateFakeComposer())
        defer { decoder.close() }

        decoder.primeForTesting(enhancementLayer: true)

        // Feed 6 consecutive base-layer frames without any EL
        for i in 1...6 {
            let bl = try #require(Self.baseLayer())
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
            // blFrameQueue count must never exceed maxLayerSkewFrames (3)
            #expect(decoder.stateSnapshotForTesting.blQueueCount <= DualLayerVideoDecoder.maxLayerSkewFrames)
        }

        // Feed more enhancement-layer frames than their cap without any BL
        for i in 10..<(10 + DualLayerVideoDecoder.maxEnhancementLayerQueueFrames + 3) {
            let el = try #require(Self.enhancementLayer())
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            // elFrameQueue count must never exceed its own cap (10)
            #expect(decoder.stateSnapshotForTesting.elQueueCount <= DualLayerVideoDecoder.maxEnhancementLayerQueueFrames)
        }
    }

    // MARK: - Stream Classification & Packet Balance Tracking

    @Test("DualLayerVideoDecoder reports streamClassification accurately and balances packets")
    func fel22StreamClassificationAndPacketBalance() throws {
        let primary = CountingFakeDecoder()
        let enhancement = CountingFakeDecoder()
        let decoder = DualLayerVideoDecoder(
            composer: ImmediateFakeComposer(),
            primaryDecoder: primary,
            enhancementDecoder: enhancement
        )
        defer { decoder.close() }

        #expect(decoder.streamClassification == .undetermined)

        // Feed MEL packets
        let vps = Self.hevcNAL(type: 32, payload: [0x0c, 0x01, 0xff, 0xff])
        let sps = Self.hevcNAL(type: 33, payload: [0x01, 0x02, 0x20, 0x00])
        let pps = Self.hevcNAL(type: 34, payload: [0xc0, 0x73])
        let bl = Self.hevcNAL(type: 1, payload: [0x11, 0x22, 0x33, 0x44])
        let melRpu = Self.makeMelRpuBytes()

        // PacketBalanceTracker is process-wide and other suites allocate packets concurrently, so an
        // exact baseline is a race. A packet leaked per decode shows up as one per iteration instead,
        // far above what the rest of the run keeps in flight.
        let iterations = 256
        let aliveBefore = PacketBalanceTracker.alive
        for i in 0..<iterations {
            guard let melPkt = Self.makeAvccPacket([vps, sps, pps, bl, melRpu], pts: 1000 + Int64(i) * 1001) else {
                Issue.record("Failed to make MEL packet")
                return
            }
            decoder.decode(packet: melPkt)
            var optMel: UnsafeMutablePointer<AVPacket>? = melPkt
            trackedPacketFree(&optMel)
        }

        // Classification must be MEL, not FEL
        #expect(decoder.streamClassification == .mel)

        #expect(PacketBalanceTracker.alive - aliveBefore < iterations / 2)
    }
}
#endif
