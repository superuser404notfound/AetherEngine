#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import AetherLibavformat
import AetherLibavcodec
@_spi(Diagnostics) @testable import AetherEngine

/// Which RPU a delivered frame carries. A composed frame has been reshaped by the composer, so its RPU
/// has no mapping; a frame shown as its raw base layer (released without its enhancement layer, or left
/// intact by a failed composition) has not, so it carries the RPU that keeps the mapping and the display
/// side reshapes it. The two RPUs are stood in for by tagged byte strings: this pins the choice, and
/// `DoviComposedFrameRpuTests` pins what the two forms contain.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DualLayerBypassRpuTests {

    private static let composedTag: UInt8 = 0xC0
    private static let baseLayerTag: UInt8 = 0xB0
    private static let composedNAL: [UInt8] = [0x7C, 0x01, 0x19, composedTag]
    private static let baseLayerNAL: [UInt8] = [0x7C, 0x01, 0x19, baseLayerTag]

    private static let frame = 1.0 / 24
    private static var margin: Double { max(Double(DualLayerVideoDecoder.deadlineMarginFrames) * frame, DualLayerVideoDecoder.deadlineMarginFloor) }
    private static func pts(_ n: Int64) -> CMTime { CMTime(value: n * 3750, timescale: 90000) }

    private static func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        guard status == kCVReturnSuccess else { throw CocoaError(.fileWriteUnknown) }
        return try #require(out)
    }

    private static func params() -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = 64; p.blHeight = 64; p.elWidth = 32; p.elHeight = 32
        return p
    }

    /// Completes at once with `result`: the base buffer (a composition) or nil (a failure).
    private final class Composer: FelComposing, @unchecked Sendable {
        let fails: Bool
        init(fails: Bool) { self.fails = fails }
        func acquireSlot() {}
        func acquireSlot(timeout: DispatchTime) -> Bool { true }
        func releaseSlot() {}
        func flush() {}
        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            completion(fails ? nil : baseBuffer)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer,
                                          params: DoviMetalParams, frameIndex: UInt32,
                                          completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            completion(fails ? nil : baseBuffer)
        }
    }

    private final class FakeSession: SingleLayerVideoDecoder, @unchecked Sendable {
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        var feedEpoch: UInt64 = 0
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {}
        func open(parameterSets: [[UInt8]], timeBase: AVRational, onFrame: @escaping DecodedFrameHandler) throws {}
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {}
        func flush() {}
        func close() {}
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var _tags: [UInt8?] = []
        func record(_ buffer: CVPixelBuffer) {
            let data = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data
            lock.lock(); _tags.append(data.flatMap { $0.count > 1 ? $0[1] : nil }); lock.unlock()
        }
        /// The tag byte of each delivered frame's RPU, nil for a frame with none.
        var tags: [UInt8?] { lock.lock(); defer { lock.unlock() }; return _tags }
        var count: Int { tags.count }
    }

    private final class Clocks: @unchecked Sendable {
        private let lock = NSLock()
        private var _seconds = 0.0, _uptime = 1000.0
        var seconds: Double { get { lock.lock(); defer { lock.unlock() }; return _seconds } set { lock.lock(); _seconds = newValue; lock.unlock() } }
        var uptime: Double { get { lock.lock(); defer { lock.unlock() }; return _uptime } set { lock.lock(); _uptime = newValue; lock.unlock() } }
    }

    private struct Rig { let decoder: DualLayerVideoDecoder; let delivered: Delivered; let clocks: Clocks }

    private static func rig(composeFails: Bool = false) -> Rig {
        let delivered = Delivered()
        let clocks = Clocks()
        let decoder = DualLayerVideoDecoder(composer: Composer(fails: composeFails), primaryDecoder: FakeSession(), enhancementDecoder: FakeSession())
        decoder.onFrame = { buffer, _, _ in delivered.record(buffer) }
        decoder.primeForTesting(enhancementLayer: true)
        decoder.uptimeProvider = { clocks.uptime }
        decoder.setRenderClock({ DualLayerVideoDecoder.RenderClockSample(seconds: clocks.seconds, running: true, prerolling: false) }, frameRate: 24)
        return Rig(decoder: decoder, delivered: delivered, clocks: clocks)
    }

    private static func feedBase(_ r: Rig, _ n: Int64, baseLayerNAL: [UInt8]? = baseLayerNAL) throws {
        r.decoder.seedRPUForTesting(pts: pts(n), params: params(), displayMetadataNAL: composedNAL, baseLayerNAL: baseLayerNAL)
        r.decoder.handleBaseLayerFrame(baseBuffer: try buffer(width: 64, height: 64), pts: pts(n), hdr10Data: nil)
    }

    @Test("a frame composed with its enhancement layer carries the RPU without a mapping")
    func composedFrameCarriesTheComposedRpu() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.buffer(width: 32, height: 32), pts: Self.pts(240))
        try Self.feedBase(r, 240)
        try await waitFor { r.delivered.count == 1 }
        #expect(r.delivered.tags == [Self.composedTag])
    }

    @Test("an access unit with no enhancement layer goes out as its base layer with the mapping-preserving RPU")
    func missingEnhancementLayerCarriesTheMappingRpu() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(240))
        try Self.feedBase(r, 240)
        try await waitFor { r.delivered.count == 1 }
        #expect(r.delivered.tags == [Self.baseLayerTag])
    }

    @Test("a frame released by its display deadline carries the mapping-preserving RPU")
    func deadlineBypassCarriesTheMappingRpu() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let n: Int64 = 252
        r.clocks.seconds = Self.pts(n).seconds - Self.margin - 0.010
        try Self.feedBase(r, n)
        r.clocks.uptime += 0.05
        r.decoder.runDeadlineSweep()
        #expect(r.delivered.count == 0, "short of its release time")
        r.clocks.seconds = Self.pts(n).seconds - Self.margin
        r.decoder.runDeadlineSweep()
        try await waitFor { r.delivered.count == 1 }
        #expect(r.delivered.tags == [Self.baseLayerTag])
    }

    @Test("a frame whose composition failed goes out as its base layer with the mapping-preserving RPU")
    func failedCompositionCarriesTheMappingRpu() async throws {
        let r = Self.rig(composeFails: true)
        defer { r.decoder.close() }
        r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.buffer(width: 32, height: 32), pts: Self.pts(240))
        try Self.feedBase(r, 240)
        try await waitFor { r.delivered.count == 1 }
        #expect(r.delivered.tags == [Self.baseLayerTag])
    }

    @Test("a frame with no mapping-preserving form falls back to the composed RPU, as before")
    func missingMappingFormFallsBack() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        nonisolated(unsafe) var now: TimeInterval = 100
        nonisolated(unsafe) var lines: [String] = []
        r.decoder.summaryTimestampProviderForTesting = { now }
        r.decoder.summarySinkForTesting = { line, _ in lines.append(line) }
        r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(240))
        try Self.feedBase(r, 240, baseLayerNAL: nil)
        r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(241))
        try Self.feedBase(r, 241)
        try await waitFor { r.delivered.count == 2 }
        #expect(r.delivered.tags == [Self.composedTag, Self.baseLayerTag])

        now = 101.5
        r.decoder.maybeEmitSummary()
        #expect(try #require(lines.last).contains("mappingFallback=1"), "the fallback is counted, so a device log can show it")
    }
}
#endif
