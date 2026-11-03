#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import AetherLibavcodec
import AetherLibavformat
@_spi(Diagnostics) @testable import AetherEngine

/// On the AVPlayer-output route the host hands the decoder the base-layer frames (`openExternalBaseLayer`,
/// `submitBaseLayerFrame`); pairing, composition and delivery are the software host's. The compose kernels
/// dither on the parity of the frame index, so what the index is decides whether two runs of one clip
/// produce the same bits.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DualLayerExternalBaseLayerTests {

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

    /// Records the frame index each composition was issued with, and whether it went into the output pool or
    /// into the base-layer buffer. It can compose in place, as the production composer can.
    private final class Composer: FelComposing, @unchecked Sendable {
        private let lock = NSLock()
        private var _indices: [UInt32] = []
        private var _inPlace = 0
        var indices: [UInt32] { lock.lock(); defer { lock.unlock() }; return _indices }
        var inPlaceCount: Int { lock.lock(); defer { lock.unlock() }; return _inPlace }
        func canComposeInPlace(baseBuffer: CVPixelBuffer, params: DoviMetalParams) -> Bool { true }
        func composeInPlaceAsyncWithAcquiredSlot(
            baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
            frameIndex: UInt32, completion: @escaping @Sendable (DoviFelComposer.InPlaceResult) -> Void
        ) {
            lock.lock(); _indices.append(frameIndex); _inPlace += 1; lock.unlock()
            completion(.composed)
        }
        func acquireSlot() {}
        func acquireSlot(timeout: DispatchTime) -> Bool { true }
        func releaseSlot() {}
        func flush() {}
        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            lock.lock(); _indices.append(frameIndex); lock.unlock()
            completion(baseBuffer)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer,
                                          params: DoviMetalParams, frameIndex: UInt32,
                                          completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            composeAsync(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer, params: params,
                         frameIndex: frameIndex, completion: completion)
        }
    }

    private final class Session: SingleLayerVideoDecoder, @unchecked Sendable {
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

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var _n = 0
        var n: Int { lock.lock(); defer { lock.unlock() }; return _n }
        func bump() { lock.lock(); _n += 1; lock.unlock() }
    }

    private static func run(external: Bool, frames: [Int64]) async throws -> [UInt32] {
        try await compose(external: external, composeInPlace: false, frames: frames).indices
    }

    private static func compose(external: Bool, composeInPlace: Bool, frames: [Int64]) async throws -> Composer {
        let composer = Composer()
        let delivered = Count()
        let decoder = DualLayerVideoDecoder(composer: composer, primaryDecoder: Session(), enhancementDecoder: Session())
        defer { decoder.close() }
        decoder.onFrame = { _, _, _ in delivered.bump() }
        decoder.primeForTesting(enhancementLayer: true)
        if external {
            let par = try #require(avcodec_parameters_alloc())
            defer { var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
            par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            par.pointee.codec_id = AV_CODEC_ID_HEVC
            try decoder.openExternalBaseLayer(codecpar: par, timeBase: AVRational(num: 1, den: 90000), frameRate: 24,
                                              composeInPlace: composeInPlace) { _, _, _ in }
            decoder.onFrame = { _, _, _ in delivered.bump() }
        }
        for n in frames {
            decoder.seedRPUForTesting(pts: pts(n), params: params(), displayMetadataNAL: [0x7C, 0x01], baseLayerNAL: [0x7C, 0x02])
            decoder.handleEnhancementLayerFrame(elBuffer: try buffer(width: 32, height: 32), pts: pts(n))
            if external {
                decoder.submitBaseLayerFrame(try buffer(width: 64, height: 64), pts: pts(n))
            } else {
                decoder.handleBaseLayerFrame(baseBuffer: try buffer(width: 64, height: 64), pts: pts(n), hdr10Data: nil)
            }
        }
        try await waitFor { delivered.n == frames.count }
        return composer
    }

    @Test("with the base layer delivered by the host, the dither index is the frame's place in the stream")
    func externalIndexFollowsThePresentationTime() async throws {
        // Frame 241 is missing, as when a frame is dropped or a run starts a frame later: the others keep their index.
        let indices = try await Self.run(external: true, frames: [240, 242, 243])
        #expect(indices == [240, 242, 243])
    }

    @Test("the host's base-layer buffers are not written unless the route asks for it")
    func externalComposesIntoThePoolByDefault() async throws {
        let composer = try await Self.compose(external: true, composeInPlace: false, frames: [240, 241, 242])
        #expect(composer.indices.count == 3)
        #expect(composer.inPlaceCount == 0, "the player's buffers are not the compose target")
    }

    @Test("the in-place opt-in writes the host's buffers")
    func externalComposesInPlaceWhenAskedTo() async throws {
        let composer = try await Self.compose(external: true, composeInPlace: true, frames: [240, 241, 242])
        #expect(composer.inPlaceCount == 3)
    }

    @Test("the software host composes in place, as it did before the route existed")
    func softwareHostComposesInPlace() async throws {
        let composer = try await Self.compose(external: false, composeInPlace: false, frames: [240, 241, 242])
        #expect(composer.inPlaceCount == 3)
    }

    @Test("on the software host the dither index still counts compositions")
    func softwareIndexCountsCompositions() async throws {
        let indices = try await Self.run(external: false, frames: [240, 242, 243])
        #expect(indices == [1, 2, 3])
    }
}
#endif
