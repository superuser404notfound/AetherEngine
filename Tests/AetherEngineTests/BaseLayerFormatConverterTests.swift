#if DualLayerDolbyVision
import Testing
import CoreVideo
import Foundation
import VideoToolbox
@testable import AetherEngine

/// The step that makes the player's base-layer buffers readable for the composer
/// (`BaseLayerFormatConverter`). The format decision, a real pixel transfer checked sample by sample, the
/// failure outcomes, the pool's limit, its release when idle, and its teardown.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct BaseLayerFormatConverterTests {

    private static let x420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    private static let packed = kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
    private static let width = 128
    private static let height = 64

    // MARK: Buffers

    private static func makeBuffer(format: OSType, ioSurface: Bool = true,
                                   width: Int = BaseLayerFormatConverterTests.width,
                                   height: Int = BaseLayerFormatConverterTests.height) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attributes: CFDictionary? = ioSurface ? [kCVPixelBufferIOSurfacePropertiesKey: [String: String]()] as CFDictionary : nil
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &out) == kCVReturnSuccess else { return nil }
        return out
    }

    /// A 10-bit code for each sample, inside the video range (64...940 luma, 64...960 chroma), different
    /// across rows and columns so a transposed, shifted or smeared plane is caught.
    private static func lumaCode(_ x: Int, _ y: Int) -> UInt16 { UInt16(64 + (x * 7 + y * 13) % 877) }
    private static func chromaCode(_ x: Int, _ y: Int, _ channel: Int) -> UInt16 {
        UInt16(64 + (x * 11 + y * 17 + channel * 101) % 897)
    }

    /// An x420 buffer holding the pattern: codes left-justified in 16-bit words.
    private static func patternX420() -> CVPixelBuffer? {
        guard let buffer = makeBuffer(format: x420) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height {
            let row = luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width { row[x] = lumaCode(x, y) << 6 }
        }
        for y in 0..<height / 2 {
            let row = chroma.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width / 2 {
                row[2 * x] = chromaCode(x, y, 0) << 6
                row[2 * x + 1] = chromaCode(x, y, 1) << 6
            }
        }
        return buffer
    }

    /// Every sample of an x420 buffer: luma then interleaved chroma words, row by row.
    private static func samples(_ buffer: CVPixelBuffer) -> (luma: [UInt16], chroma: [UInt16]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        func plane(_ index: Int, wordsPerRow: Int) -> [UInt16] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index) else { return [] }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
            var out: [UInt16] = []
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, index) {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                out.append(contentsOf: UnsafeBufferPointer(start: row, count: wordsPerRow))
            }
            return out
        }
        return (plane(0, wordsPerRow: CVPixelBufferGetWidthOfPlane(buffer, 0)),
                plane(1, wordsPerRow: CVPixelBufferGetWidthOfPlane(buffer, 1) * 2))
    }

    /// The packed lossless buffer of the pattern, made by a pixel transfer from the x420 pattern (the format
    /// is lossless, so the pattern is what a transfer back must give). Nil where the system cannot make one.
    private static func packedPattern() -> CVPixelBuffer? {
        guard let source = patternX420(), let destination = makeBuffer(format: packed) else { return nil }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let session else { return nil }
        defer { VTPixelTransferSessionInvalidate(session) }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else { return nil }
        return destination
    }

    private static let canMakePackedBuffers = packedPattern() != nil

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 100.0
        var now: Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// A source that needs a conversion on every machine: 8-bit biplanar video range.
    private static func eightBitSource() -> CVPixelBuffer? { makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }

    // MARK: Format decision

    @Test("only an IOSurface-backed x420 buffer goes straight to the composer")
    func decisionPassesOnlyReadableBuffersThrough() {
        typealias C = BaseLayerFormatConverter
        #expect(C.decision(format: Self.x420, hasIOSurface: true) == .passThrough)
        #expect(C.decision(format: Self.x420, hasIOSurface: false) == .convert, "the composer's textures come from the surface")
        #expect(C.decision(format: Self.packed, hasIOSurface: true) == .convert)
        #expect(C.decision(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, hasIOSurface: true) == .convert)
        #expect(C.decision(format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, hasIOSurface: true) == .convert)
        let buffer = Self.makeBuffer(format: Self.x420)
        #expect(buffer.map(C.decision(for:)) == .passThrough, "the decision reads the buffer's own format and surface")
        let plain = Self.makeBuffer(format: Self.x420, ioSurface: false)
        #expect(plain.map(C.decision(for:)) == .convert)
    }

    @Test("an x420 buffer is handed on as it is: no session, no pool, no transfer")
    func x420PassesThroughUntouched() throws {
        let transfers = TransferLog()
        let converter = BaseLayerFormatConverter(transfer: transfers.transfer(returning: noErr))
        let buffer = try #require(Self.patternX420())
        guard case .ready(let out) = converter.prepare(buffer) else { Issue.record("not ready"); return }
        #expect(out === buffer)
        #expect(transfers.count == 0)
        let stats = converter.statistics
        #expect(stats.passedThrough == 1 && stats.converted == 0 && stats.peakLive == 0)
    }

    private final class TransferLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func transfer(returning status: OSStatus) -> BaseLayerFormatConverter.Transfer {
            { [self] _, _, _ in lock.lock(); calls += 1; lock.unlock(); return status }
        }
    }

    // MARK: A real transfer

    @Test("the packed lossless format converts to x420 sample for sample", .enabled(if: BaseLayerFormatConverterTests.canMakePackedBuffers, "needs a system that makes the packed format by pixel transfer"))
    func packedFormatConvertsExactly() throws {
        let converter = BaseLayerFormatConverter()
        let packedBuffer = try #require(Self.packedPattern())
        #expect(CVPixelBufferGetPixelFormatType(packedBuffer) == Self.packed)
        guard case .ready(let out) = converter.prepare(packedBuffer) else { Issue.record("not ready"); return }
        #expect(CVPixelBufferGetPixelFormatType(out) == Self.x420)
        #expect(CVPixelBufferGetIOSurface(out) != nil, "the composer reads the surface")
        #expect(CVPixelBufferGetWidth(out) == Self.width && CVPixelBufferGetHeight(out) == Self.height)
        let result = Self.samples(out)
        #expect(result.luma.count == Self.width * Self.height)
        #expect(result.chroma.count == Self.width * Self.height / 2)
        var lumaWrong = 0, chromaWrong = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where result.luma[y * Self.width + x] != Self.lumaCode(x, y) << 6 { lumaWrong += 1 }
        }
        for y in 0..<Self.height / 2 {
            for x in 0..<Self.width / 2 {
                if result.chroma[y * Self.width + 2 * x] != Self.chromaCode(x, y, 0) << 6 { chromaWrong += 1 }
                if result.chroma[y * Self.width + 2 * x + 1] != Self.chromaCode(x, y, 1) << 6 { chromaWrong += 1 }
            }
        }
        #expect(lumaWrong == 0, "luma samples differing from the source picture")
        #expect(chromaWrong == 0, "chroma samples differing from the source picture")
        #expect(converter.statistics.converted == 1)
    }

    @Test("a converted buffer keeps the source's colour tags and the attachments that travel with the picture")
    func attachmentsFollowThePicture() throws {
        let converter = BaseLayerFormatConverter()
        let source = try #require(Self.eightBitSource())
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        // Not a tag the transfer interprets: a plain attachment that must arrive with the picture.
        CVBufferSetAttachment(source, "AetherTestAttachment" as CFString, "kept" as CFString, .shouldPropagate)
        guard case .ready(let out) = converter.prepare(source) else { Issue.record("not ready"); return }
        #expect(CVBufferCopyAttachment(out, "AetherTestAttachment" as CFString, nil) as? String == "kept")
        func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(out, key, nil) as? String }
        #expect(tag(kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(tag(kCVImageBufferTransferFunctionKey) == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(tag(kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
    }

    // MARK: Failure

    @Test("a transfer that fails hands nothing on and counts the frame")
    func failedTransferHandsNothingOn() throws {
        let transfers = TransferLog()
        let converter = BaseLayerFormatConverter(transfer: transfers.transfer(returning: kVTParameterErr))
        let source = try #require(Self.eightBitSource())
        guard case .failed(let reason) = converter.prepare(source) else { Issue.record("a failed transfer was handed on"); return }
        #expect(reason.contains("\(kVTParameterErr)"))
        #expect(transfers.count == 1)
        let stats = converter.statistics
        #expect(stats.failed == 1 && stats.converted == 0 && stats.passedThrough == 0)
    }

    @Test("a failure does not leave the converter unusable: the next frame converts")
    func recoversAfterATransientFailure() throws {
        let fail = TransferLog()
        let converter = BaseLayerFormatConverter(transfer: { session, source, destination in
            fail.count == 0 ? fail.transfer(returning: kVTParameterErr)(session, source, destination)
                : VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        })
        let source = try #require(Self.eightBitSource())
        if case .ready = converter.prepare(source) { Issue.record("the first frame should have failed") }
        guard case .ready = converter.prepare(source) else { Issue.record("the second frame did not convert"); return }
        #expect(converter.statistics.failed == 1 && converter.statistics.converted == 1)
    }

    // MARK: The pool

    @Test("the pool refuses a buffer past its limit while they are held, and serves again when one is released")
    func poolLimitRefusesThenHeals() throws {
        let converter = BaseLayerFormatConverter(poolLimit: 2, retryAttempts: 1)
        let source = try #require(Self.eightBitSource())
        var held: [CVPixelBuffer] = []
        for _ in 0..<2 {
            guard case .ready(let out) = converter.prepare(source) else { Issue.record("a buffer within the limit was refused"); return }
            held.append(out)
        }
        guard case .refused = converter.prepare(source) else { Issue.record("a buffer past the limit was served"); return }
        #expect(converter.statistics.refused == 1)
        #expect(converter.statistics.failed == 0, "a refusal is not a failure")
        #expect(converter.statistics.peakLive == 2)
        held.removeFirst()
        // A released buffer returns to the pool once the system is done with its surface, which is not
        // instant for a surface a transfer has just written.
        var served = false
        for _ in 0..<200 where !served {
            if case .ready = converter.prepare(source) { served = true } else { Thread.sleep(forTimeInterval: 0.01) }
        }
        #expect(served, "a released buffer was never served again \(converter.statistics)")
        #expect(held.count == 1)
    }

    @Test("the default pool limit and idle period are the measured ones")
    func defaults() {
        #expect(BaseLayerFormatConverter.poolLimit == 6)
        #expect(BaseLayerFormatConverter.idleTrimSeconds == 1.0)
    }

    private final class FlushLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func record() { lock.lock(); calls += 1; lock.unlock() }
    }

    @Test("a pool idle for a second gives its buffers back, again every idle second, and a conversion restarts the wait")
    func idlePoolReleasesItsBuffers() throws {
        let clock = Clock()
        let flushes = FlushLog()
        let converter = BaseLayerFormatConverter(now: { clock.now }, flush: { _ in flushes.record() })
        let source = try #require(Self.eightBitSource())
        converter.trimIfIdle()
        #expect(flushes.count == 0, "no pool yet, nothing to release")
        guard case .ready = converter.prepare(source) else { Issue.record("not ready"); return }
        clock.advance(0.9)
        converter.trimIfIdle()
        #expect(flushes.count == 0, "0.9 s idle is not a second")
        guard case .ready = converter.prepare(source) else { Issue.record("not ready"); return }
        clock.advance(0.9)
        converter.trimIfIdle()
        #expect(flushes.count == 0, "a conversion restarts the wait")
        clock.advance(0.2)
        converter.trimIfIdle()
        #expect(flushes.count == 1, "a second idle releases the pool's idle buffers")
        converter.trimIfIdle()
        #expect(flushes.count == 1, "not on every tick")
        clock.advance(1.1)
        converter.trimIfIdle()
        #expect(flushes.count == 2, "a buffer still held downstream at the first trim is released by a later one")
    }

    @Test("a pool that was trimmed serves the next frame")
    func trimmedPoolStillConverts() throws {
        let clock = Clock()
        let converter = BaseLayerFormatConverter(now: { clock.now })
        let source = try #require(Self.eightBitSource())
        guard case .ready = converter.prepare(source) else { Issue.record("not ready"); return }
        clock.advance(2)
        converter.trimIfIdle()
        guard case .ready(let out) = converter.prepare(source) else { Issue.record("not ready after a trim"); return }
        #expect(CVPixelBufferGetPixelFormatType(out) == Self.x420)
    }

    @Test("a picture of another size gets a pool of its own")
    func sizeChangeStartsANewPool() throws {
        let converter = BaseLayerFormatConverter()
        let small = try #require(Self.eightBitSource())
        let large = try #require(Self.makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 256, height: 128))
        guard case .ready(let a) = converter.prepare(small), case .ready(let b) = converter.prepare(large) else {
            Issue.record("not ready"); return
        }
        #expect(CVPixelBufferGetWidth(a) == Self.width && CVPixelBufferGetWidth(b) == 256)
        #expect(CVPixelBufferGetHeight(b) == 128)
    }

    // MARK: Teardown

    @Test("after the teardown nothing converts, the pool was released, and the idle trim is harmless")
    func tearDownEndsTheConverter() throws {
        let flushes = FlushLog()
        let converter = BaseLayerFormatConverter(flush: { _ in flushes.record() })
        let source = try #require(Self.eightBitSource())
        guard case .ready = converter.prepare(source) else { Issue.record("not ready"); return }
        #expect(flushes.count == 0)
        converter.tearDown()
        #expect(flushes.count == 1, "the pool's buffers were released with the converter")
        guard case .failed = converter.prepare(source) else { Issue.record("a closed converter converted"); return }
        converter.trimIfIdle()
        converter.tearDown()
        #expect(flushes.count == 1, "a second teardown and a trim after it release nothing more")
        // A buffer the composer can read passes through as before; the route stops handing it frames anyway.
        let ready = try #require(Self.patternX420())
        guard case .ready(let same) = converter.prepare(ready) else { Issue.record("not ready"); return }
        #expect(same === ready)
    }
}
#endif
