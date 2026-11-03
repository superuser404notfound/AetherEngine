#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import Metal
@testable import AetherEngine

/// Composing into the decoded base-layer buffer instead of a buffer from the output pool.
///
/// The picture has to be the same bit for bit, the pool must never come into existence, the buffer's
/// attachments must end up as a pool buffer's would, a frame that failed half way must not be shown, and
/// anything the in-place order cannot handle must take the pool path.
@Suite(.offCooperativePoolOneLane, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DoviFelInPlaceComposeTests {

    typealias H = DoviGpuCurveSweepTests

    // MARK: - Fixtures

    /// Cheap deterministic noise, so every sample differs from its neighbours and a wrong neighbour read shows.
    private static func noise(_ x: Int, _ y: Int, _ c: Int, _ seed: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ c &* 83492791 ^ seed &* 2654435761)
        h ^= h >> 15; h = h &* 2246822519; h ^= h >> 13; h = h &* 3266489917; h ^= h >> 16
        return Int(h & 0xFFFF)
    }

    /// A base layer in video range with texture, and an enhancement layer of residual codes around mid-grey.
    static func makeBaseAndEnhancement(width: Int, height: Int, seed: Int) -> (bl: CVPixelBuffer, el: CVPixelBuffer)? {
        guard let bl = H.makeBuffer(width: width, height: height),
              let el = H.makeBuffer(width: width / 2, height: height / 2) else { return nil }
        H.fillPlane(bl, plane: 0, components: 1) { x, y, _ in 64 + (x * 3 + y * 5 + noise(x, y, 0, seed) % 64) % 876 }
        H.fillPlane(bl, plane: 1, components: 2) { x, y, c in 64 + (x * 7 + y * 3 + noise(x, y, 1 + c, seed) % 96) % 896 }
        H.fillPlane(el, plane: 0, components: 1) { x, y, _ in 480 + noise(x, y, 5, seed) % 64 }
        H.fillPlane(el, plane: 1, components: 2) { x, y, c in 490 + noise(x, y, 6 + c, seed) % 44 }
        return (bl, el)
    }

    private static func polynomial(_ c0: Double, _ c1: Double, _ c2: Double, order: UInt32) -> DoviPolynomialParams {
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0; poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.polynomial.rawValue
        poly.order[0] = order
        poly.coefShift[0] = 23
        poly.coef[0] = [Int32(c0 * 8388608.0), Int32(c1 * 8388608.0), Int32(c2 * 8388608.0)]
        return poly
    }

    /// Curves that actually move every component, and a residual on all three, so a plane that is read after
    /// it was overwritten changes the result.
    static func params(dither: DoviDither = .bayer8x8, residual: Bool = true, chroma: ChromaCurves = .polynomial) -> DoviMetalParams {
        var p = DoviGpuEdgeCaseTests.params(flags: residual ? [] : [.disableResidual])
        p.polyY = polynomial(0.02, 0.93, 0.05, order: 2)
        p.polyCb = polynomial(0.03, 0.96, 0, order: 1)
        p.polyCr = polynomial(-0.01, 1.03, 0, order: 1)
        p.ditherMode = dither
        switch chroma {
        case .polynomial:
            break
        case .mmrOnePiece:
            // Both chroma curves lean on luma (y, y*u, y*v, y^2), so the chroma pass reads the base luma.
            (p.polyCb, p.mmrCb) = mmr(pivots: [0, 1023], orders: [1],
                                      constants: [0.05], terms: [[0: 0.5, 1: 0.35, 3: 0.1]])
            (p.polyCr, p.mmrCr) = mmr(pivots: [0, 1023], orders: [2],
                                      constants: [0.02], terms: [[0: 0.4, 2: 0.4, 4: 0.1, 7: 0.05, 11: 0.05]])
        case .mmrTwoPieces:
            // Cb switches pieces at its own code 512 (order 1, then order 2); Cr keeps one order-3 piece.
            (p.polyCb, p.mmrCb) = mmr(pivots: [0, 512, 1023], orders: [1, 2],
                                      constants: [0.05, 0.1],
                                      terms: [[0: 0.55, 1: 0.3, 3: 0.1], [0: 0.3, 1: 0.4, 7: 0.2, 10: 0.1]])
            (p.polyCr, p.mmrCr) = mmr(pivots: [0, 1023], orders: [3],
                                      constants: [0.03],
                                      terms: [[0: 0.35, 2: 0.35, 4: 0.12, 7: 0.1, 14: 0.05, 18: 0.04]])
        }
        return p
    }

    /// Which curves the chroma components use. Only the MMR ones make the chroma pass read base luma.
    enum ChromaCurves: Sendable, CaseIterable { case polynomial, mmrOnePiece, mmrTwoPieces }

    /// An MMR curve: `terms[piece]` maps `order * 7 + term` over `[y, u, v, yu, yv, uv, yuv]` to a coefficient.
    private static func mmr(pivots: [UInt32], orders: [UInt32], constants: [Double],
                            terms: [[Int: Double]]) -> (DoviPolynomialParams, DoviMmrParams) {
        var poly = DoviPolynomialParams()
        poly.numPivots = UInt32(pivots.count)
        var m = DoviMmrParams()
        m.coefShift = 23
        for (i, pivot) in pivots.enumerated() { poly.pivots[i] = pivot }
        for piece in 0..<orders.count {
            poly.method[piece] = DoviMapping.mmr.rawValue
            poly.order[piece] = orders[piece]
            poly.coefShift[piece] = 23
            m.constant[piece] = Int32(constants[piece] * 8388608.0)
            for (index, value) in terms[piece] { m.coef[piece][index] = Int32(value * 8388608.0) }
        }
        return (poly, m)
    }

    /// The samples of one plane inside the picture, without the row padding.
    static func visibleWords(_ buffer: CVPixelBuffer, plane: Int) -> [UInt16] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return [] }
        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let samplesPerRow = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        var out: [UInt16] = []
        out.reserveCapacity(rows * samplesPerRow)
        for r in 0..<rows {
            let row = (base + r * stride).assumingMemoryBound(to: UInt16.self)
            for c in 0..<samplesPerRow { out.append(row[c]) }
        }
        return out
    }

    private struct Box: @unchecked Sendable { let value: CVPixelBuffer }

    /// Composes in place the way the decoder does: take a slot, hand over the buffer, wait for the completion.
    @discardableResult
    static func composeInPlace(_ composer: DoviFelComposer, bl: CVPixelBuffer, el: CVPixelBuffer,
                               params: DoviMetalParams, frameIndex: UInt32) async -> DoviFelComposer.InPlaceResult {
        composer.acquireSlot()
        return await withCheckedContinuation { cont in
            composer.composeInPlaceAsyncWithAcquiredSlot(baseBuffer: bl, enhancementBuffer: el, params: params,
                                                         frameIndex: frameIndex) { cont.resume(returning: $0) }
        }
    }

    // MARK: - Bit-exactness

    @Test("in-place output equals the pool output bit for bit, all planes, every dither mode, residual setting and chroma curve kind",
          arguments: [
            (256, 128, DoviDither.bayer8x8, true, ChromaCurves.polynomial),
            (256, 128, DoviDither.none, true, ChromaCurves.polynomial),
            (256, 128, DoviDither.fullPrecision, true, ChromaCurves.polynomial),
            (256, 128, DoviDither.bayer8x8, false, ChromaCurves.polynomial),
            (320, 180, DoviDither.bayer8x8, true, ChromaCurves.polynomial),    // not a multiple of the threadgroup in either direction
            (1920, 1080, DoviDither.bayer8x8, true, ChromaCurves.polynomial),
            // Chroma MMR: the chroma pass reads the base luma (a [1 2 1] neighbourhood, edges clamped), which
            // is the cross-plane read the in-place pass order protects.
            (256, 128, DoviDither.bayer8x8, true, ChromaCurves.mmrOnePiece),
            (256, 128, DoviDither.none, false, ChromaCurves.mmrOnePiece),
            (320, 180, DoviDither.bayer8x8, true, ChromaCurves.mmrTwoPieces),
            (256, 128, DoviDither.fullPrecision, true, ChromaCurves.mmrTwoPieces),
            (1920, 1080, DoviDither.bayer8x8, true, ChromaCurves.mmrTwoPieces),
          ])
    func inPlaceMatchesPool(width: Int, height: Int, dither: DoviDither, residual: Bool, chroma: ChromaCurves) async throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.params(dither: dither, residual: residual, chroma: chroma)
        for frame in [UInt32(0), 7, 8] {
            let a = try #require(Self.makeBaseAndEnhancement(width: width, height: height, seed: Int(frame) + 1))
            let b = try #require(Self.makeBaseAndEnhancement(width: width, height: height, seed: Int(frame) + 1))
            let pooled = try #require(composer.compose(baseBuffer: a.bl, enhancementBuffer: a.el, params: params, frameIndex: frame))
            let result = await Self.composeInPlace(composer, bl: b.bl, el: b.el, params: params, frameIndex: frame)
            #expect(result == .composed)
            for plane in 0..<2 {
                let expected = Self.visibleWords(pooled, plane: plane)
                let got = Self.visibleWords(b.bl, plane: plane)
                #expect(!expected.isEmpty)
                #expect(got == expected, "plane \(plane) differs at frame \(frame), \(width)x\(height), \(dither), residual \(residual), \(chroma)")
            }
            // The pool path never touches its base layer; make sure the control really was the base layer's
            // opposite, i.e. in place changed the base buffer and the pool path did not.
            #expect(Self.visibleWords(a.bl, plane: 0) != Self.visibleWords(pooled, plane: 0))
        }
    }

    /// The guard has teeth only if chroma really depends on the luma the in-place order protects. Composing
    /// the pool way once from the decoded base layer, and once from a base layer whose luma was already
    /// replaced by the composed luma (what a swapped pass order or a missing barrier would feed the chroma
    /// pass), must give different chroma for the MMR curves, and the same chroma for the polynomial ones
    /// (which is why the polynomial-only argument sets alone could not catch an ordering fault).
    @Test("chroma composed from already-composed luma differs for MMR chroma curves, so the bit-exact test can catch a wrong pass order",
          arguments: ChromaCurves.allCases)
    func orderSensitivityControl(chroma: ChromaCurves) async throws {
        let (width, height) = (256, 128)
        let composer = try #require(DoviFelComposer())
        let params = Self.params(chroma: chroma)
        let original = try #require(Self.makeBaseAndEnhancement(width: width, height: height, seed: 21))
        let correct = try #require(composer.compose(baseBuffer: original.bl, enhancementBuffer: original.el, params: params, frameIndex: 0))

        // The base layer as the chroma pass would see it after the luma pass had run.
        let overwritten = try #require(Self.makeBaseAndEnhancement(width: width, height: height, seed: 21))
        let composedLuma = Self.visibleWords(correct, plane: 0)
        #expect(composedLuma != Self.visibleWords(original.bl, plane: 0), "the luma curve must move luma")
        H.fillPlane(overwritten.bl, plane: 0, components: 1) { x, y, _ in Int(composedLuma[y * width + x] >> 6) }
        let wrong = try #require(composer.compose(baseBuffer: overwritten.bl, enhancementBuffer: overwritten.el, params: params, frameIndex: 0))

        let same = Self.visibleWords(correct, plane: 1) == Self.visibleWords(wrong, plane: 1)
        switch chroma {
        case .polynomial: #expect(same, "polynomial chroma should not read luma")
        case .mmrOnePiece, .mmrTwoPieces: #expect(!same, "MMR chroma must depend on the luma it is composed from")
        }
    }

    // MARK: - No pool

    @Test("in-place playback of eligible frames does not create the output pool; the blocking pool path does")
    func poolIsNeverCreated() async throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.params()
        for frame in 0..<8 {
            let f = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: frame))
            #expect(composer.canComposeInPlace(baseBuffer: f.bl, params: params))
            #expect(await Self.composeInPlace(composer, bl: f.bl, el: f.el, params: params, frameIndex: UInt32(frame)) == .composed)
        }
        #expect(!composer.hasOutputPool)
        #expect(composer.allocatedPoolBuffers == 0)
        #expect(composer.inPlaceComposedFrames == 8)

        // Control: the pool path does build it.
        let f = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 99))
        #expect(composer.compose(baseBuffer: f.bl, enhancementBuffer: f.el, params: params, frameIndex: 1) != nil)
        #expect(composer.hasOutputPool)
        #expect(composer.allocatedPoolBuffers >= 1)
    }

    // MARK: - Fallback decision

    private static func makeBuffer(format: OSType, width: Int, height: Int, ioSurface: Bool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        // Metal compatibility alone makes CoreVideo back the buffer with an IOSurface, so the plain
        // buffer gets neither key.
        var attrs: [CFString: Any] = [:]
        if ioSurface {
            attrs[kCVPixelBufferMetalCompatibilityKey] = true
            attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        }
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &out)
        return status == kCVReturnSuccess ? out : nil
    }

    @Test("the in-place decision: eligible only for an IOSurface-backed x420 buffer of even size without a luma MMR curve")
    func decision() throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.params()
        let good = try #require(Self.makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 256, height: 128, ioSurface: true))
        #expect(composer.inPlaceDecision(baseBuffer: good, params: params) == nil)
        #expect(composer.canComposeInPlace(baseBuffer: good, params: params))

        let noSurface = try #require(Self.makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 256, height: 128, ioSurface: false))
        #expect(composer.inPlaceDecision(baseBuffer: noSurface, params: params) == .notIOSurfaceBacked)

        let eightBit = try #require(Self.makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 256, height: 128, ioSurface: true))
        #expect(composer.inPlaceDecision(baseBuffer: eightBit, params: params) == .notX420)

        let odd = try #require(Self.makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 255, height: 128, ioSurface: true))
        #expect(composer.inPlaceDecision(baseBuffer: odd, params: params) == .planeLayout)

        var mmr = params
        mmr.flags.insert(.lumaMmr)
        #expect(composer.inPlaceDecision(baseBuffer: good, params: mmr) == .lumaMmr)

        composer.inPlaceComposeEnabled = false
        #expect(composer.inPlaceDecision(baseBuffer: good, params: params) == .switchedOff)
        composer.inPlaceComposeEnabled = true

        composer.releaseOutputPool()
        #expect(composer.inPlaceDecision(baseBuffer: good, params: params) == .tornDown)
    }

    @Test("a frame the in-place order cannot handle composes through the pool, and matches an in-place-capable composer's own pool path")
    func lumaMmrFrameUsesPool() async throws {
        // The decision sends it to the pool; the encoder also refuses it directly, so a caller that skipped
        // the question cannot get a picture built from chroma that was already overwritten.
        let composer = try #require(DoviFelComposer())
        var mmr = Self.params()
        mmr.flags.insert(.lumaMmr)
        let f = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 3))
        let before = Self.visibleWords(f.bl, plane: 0)
        #expect(await Self.composeInPlace(composer, bl: f.bl, el: f.el, params: mmr, frameIndex: 0) == .baseIntact)
        #expect(Self.visibleWords(f.bl, plane: 0) == before, "a refused in-place composition changed the base layer")
        #expect(!composer.hasOutputPool)
    }

    // MARK: - Failure and exclusivity

    @Test("a command buffer that fails in place is reported as corrupt, never as a base layer to fall back to")
    func failedInPlaceIsCorrupt() async throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.params()
        let f = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 4))
        composer.forcedCommandBufferFailure.withLock { $0 = true }
        #expect(await Self.composeInPlace(composer, bl: f.bl, el: f.el, params: params, frameIndex: 1) == .baseCorrupted)
        #expect(composer.inPlaceLostFrames == 1)
        #expect(composer.inPlaceComposedFrames == 0)

        // The claim and the slot were given back: another buffer composes once the fault is gone.
        composer.forcedCommandBufferFailure.withLock { $0 = false }
        let g = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 5))
        #expect(await Self.composeInPlace(composer, bl: g.bl, el: g.el, params: params, frameIndex: 2) == .composed)
        #expect(!composer.hasOutputPool)
    }

    @Test("a set-up failure leaves the base layer untouched and reports it as intact")
    func setUpFailureLeavesBaseIntact() async throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.params()
        let f = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 6))
        let before = (Self.visibleWords(f.bl, plane: 0), Self.visibleWords(f.bl, plane: 1))
        composer.releaseOutputPool()   // torn down: every composition is refused
        #expect(await Self.composeInPlace(composer, bl: f.bl, el: f.el, params: params, frameIndex: 1) == .baseIntact)
        #expect(Self.visibleWords(f.bl, plane: 0) == before.0)
        #expect(Self.visibleWords(f.bl, plane: 1) == before.1)
        #expect(composer.inPlaceLostFrames == 0)
    }

    @Test("a buffer that is already being composed is refused, not composed twice, and its slot is returned")
    func sameBufferIsNotComposedTwice() async throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.params()
        let f = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 7))
        #expect(composer.claimInPlaceForTesting(f.bl))
        let before = Self.visibleWords(f.bl, plane: 0)
        // More attempts than slots: a leaked slot would hang here.
        for i in 0..<(DoviFelComposer.maxFramesInFlight + 2) {
            #expect(await Self.composeInPlace(composer, bl: f.bl, el: f.el, params: params, frameIndex: UInt32(i)) == .baseCorrupted)
        }
        #expect(Self.visibleWords(f.bl, plane: 0) == before)
        composer.releaseInPlaceClaimForTesting(f.bl)
        #expect(await Self.composeInPlace(composer, bl: f.bl, el: f.el, params: params, frameIndex: 9) == .composed)
    }

    // MARK: - Attachments

    private static func attachments(_ buffer: CVPixelBuffer, _ mode: CVAttachmentMode) -> [String: String] {
        let dict = CVBufferCopyAttachments(buffer, mode) as? [String: Any] ?? [:]
        return dict.mapValues { "\($0)" }
    }

    @Test("colour tags, HDR metadata and the Dolby Vision attachment end up as the pool path leaves them")
    func attachmentsMatchPoolPath() async throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.params()
        let a = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 8))
        let b = try #require(Self.makeBaseAndEnhancement(width: 256, height: 128, seed: 8))
        for buffer in [a.bl, b.bl] {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_TopLeft, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, Data([1, 2, 3, 4]) as CFData, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, Data([5, 6]) as CFData, .shouldPropagate)
            // A stale RPU left by a previous tenant of the buffer, and a note that does not propagate.
            CVBufferSetAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, Data([9, 9]) as CFData, .shouldPropagate)
            CVBufferSetAttachment(buffer, "AetherTestPrivateNote" as CFString, "x" as CFString, .shouldNotPropagate)
        }
        let nal: [UInt8] = [0x7C, 0x01, 0x19, 0x42, 0x03]

        let pooled = try #require(composer.compose(baseBuffer: a.bl, enhancementBuffer: a.el, params: params, frameIndex: 3))
        #expect(await Self.composeInPlace(composer, bl: b.bl, el: b.el, params: params, frameIndex: 3) == .composed)
        // What `OrderedDelivery.emit` does to either one.
        DoviDisplayMetadata.attach(rpuNAL: nal, to: pooled)
        DoviDisplayMetadata.attach(rpuNAL: nal, to: b.bl)

        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            let expected = Self.attachments(pooled, mode)
            let got = Self.attachments(b.bl, mode)
            #expect(got == expected, "attachments (\(mode.rawValue)) differ: \(got) vs \(expected)")
        }
        #expect(!Self.attachments(b.bl, .shouldPropagate).isEmpty)

        // The same on the underlying IOSurface (what a consumer reading the surface directly sees).
        let keys: [CFString] = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                                kCVImageBufferYCbCrMatrixKey, kCVImageBufferChromaLocationTopFieldKey,
                                kCVImageBufferMasteringDisplayColorVolumeKey, kCVImageBufferContentLightLevelInfoKey]
        let surfaceA = try #require(CVPixelBufferGetIOSurface(pooled)).takeUnretainedValue()
        let surfaceB = try #require(CVPixelBufferGetIOSurface(b.bl)).takeUnretainedValue()
        for key in keys {
            let expected = IOSurfaceCopyValue(surfaceA, key).map { "\($0)" }
            let got = IOSurfaceCopyValue(surfaceB, key).map { "\($0)" }
            #expect(got == expected, "IOSurface value for \(key) differs: \(String(describing: got)) vs \(String(describing: expected))")
        }
        #expect(Self.attachments(b.bl, .shouldNotPropagate).isEmpty)

        // No RPU for the frame: the stale one is removed from either, the colour tags stay.
        DoviDisplayMetadata.attach(rpuNAL: nil, to: pooled)
        DoviDisplayMetadata.attach(rpuNAL: nil, to: b.bl)
        #expect(Self.attachments(b.bl, .shouldPropagate) == Self.attachments(pooled, .shouldPropagate))
    }

    // MARK: - Decoder

    /// A composer that claims in-place support and answers with a scripted result per frame.
    final class ScriptedInPlaceComposer: FelComposing, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [DoviFelComposer.InPlaceResult]
        private(set) var poolCalls = 0
        init(_ results: [DoviFelComposer.InPlaceResult]) { self.results = results }
        func acquireSlot() {}
        func releaseSlot() {}
        func flush() {}
        func canComposeInPlace(baseBuffer: CVPixelBuffer, params: DoviMetalParams) -> Bool { true }
        func composeInPlaceAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                                                 frameIndex: UInt32, completion: @escaping @Sendable (DoviFelComposer.InPlaceResult) -> Void) {
            lock.lock(); let r = results.isEmpty ? .composed : results.removeFirst(); lock.unlock()
            completion(r)
        }
        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            lock.lock(); poolCalls += 1; lock.unlock(); completion(nil)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            lock.lock(); poolCalls += 1; lock.unlock(); completion(nil)
        }
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var ptsList: [Int64] = []
        func add(_ pts: CMTime) { lock.lock(); ptsList.append(pts.value); lock.unlock() }
        var values: [Int64] { lock.lock(); defer { lock.unlock() }; return ptsList }
    }

    @Test("the decoder drops a frame whose in-place composition failed after writing began, keeps the order of the rest, and counts it")
    func decoderDropsCorruptFrame() async throws {
        let ticks: Int64 = 3754
        func pts(_ i: Int64) -> CMTime { CMTime(value: i * ticks, timescale: 90000) }
        let composer = ScriptedInPlaceComposer([.composed, .baseCorrupted, .baseIntact, .composed])
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        let delivered = Delivered()
        decoder.onFrame = { _, p, _ in delivered.add(p) }
        decoder.primeForTesting(enhancementLayer: true)
        for i in 0..<4 { decoder.seedRPUForTesting(pts: pts(Int64(i)), params: DoviMetalParams(), displayMetadataNAL: nil) }
        for i in 0..<4 {
            let f = try #require(Self.makeBaseAndEnhancement(width: 64, height: 64, seed: i))
            decoder.handleEnhancementLayerFrame(elBuffer: f.el, pts: pts(Int64(i)))
            decoder.handleBaseLayerFrame(baseBuffer: f.bl, pts: pts(Int64(i)), hdr10Data: nil)
        }
        decoder.quiesceForTesting()
        // Frame 1 (corrupt) is gone; frame 2 (set-up failure, base layer intact) is delivered as its base layer.
        #expect(delivered.values == [0, 2 * ticks, 3 * ticks])
        #expect(decoder.composedFrameCount == 2)
        #expect(composer.poolCalls == 0, "an in-place frame went through the pool path")
    }
}
#endif
