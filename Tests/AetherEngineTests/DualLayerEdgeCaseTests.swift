// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import AetherLibavformat
@_spi(Diagnostics) @testable import AetherEngine

/// Edge cases of the Profile 7 FEL dual-layer route that the other `DualLayer*` suites do not pin:
/// a residual that switches off and on mid-title, unclassifiable first RPUs, damaged or late enhancement
/// layers, the pixel-rate budget at its boundary, 1001-based timebases, and seeks that land on 0, on a
/// replayed range, or in a burst. Everything is synthetic: tagged pixel buffers into the frame handlers,
/// a recording composer, no media and no GPU.
@Suite(.serialized, .offCooperativePool, .timeLimit(.minutes(3)))
struct DualLayerEdgeCaseTests {

    // MARK: - Fixtures

    private static func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        return status == kCVReturnSuccess ? out : nil
    }

    private static func baseLayer() throws -> CVPixelBuffer { try #require(buffer(width: 64, height: 64)) }
    private static func enhancementLayer() throws -> CVPixelBuffer { try #require(buffer(width: 32, height: 32)) }

    private static func params() -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = 64; p.blHeight = 64; p.elWidth = 32; p.elHeight = 32
        return p
    }

    /// 23.976 fps exactly: frame n at n * 1001 / 24000 s.
    private static func pts2397(_ frame: Int64) -> CMTime { CMTime(value: frame * 1001, timescale: 24000) }
    /// 24 fps at 90 kHz.
    private static func pts(_ frame: Int64) -> CMTime { CMTime(value: frame * 3750, timescale: 90000) }

    private struct Pair { let base: CVPixelBuffer; let enhancement: CVPixelBuffer; let flags: DoviComposerFlags }

    /// Completes every composition at once with the base buffer and records what it was asked to compose.
    private final class RecordingComposer: FelComposing, @unchecked Sendable {
        private let lock = NSLock()
        private var _pairs: [Pair] = []
        private var _flushes = 0
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
            _pairs.append(Pair(base: baseBuffer, enhancement: enhancementBuffer, flags: params.flags))
            lock.unlock()
            completion(baseBuffer)
        }
    }

    /// A VideoToolbox session stand-in that only counts flushes.
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
        var all: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
        var afterMarker: [Frame] { all.filter(\.afterMarker) }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    private struct Rig {
        let decoder: DualLayerVideoDecoder
        let composer: RecordingComposer
        let primary: FakeSession
        let enhancement: FakeSession
        let deliveries: Deliveries
    }

    private static func rig() -> Rig {
        let composer = RecordingComposer()
        let primary = FakeSession(), enhancement = FakeSession()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer, primaryDecoder: primary,
                                            enhancementDecoder: enhancement)
        decoder.onFrame = { buffer, pts, _ in deliveries.record(buffer, pts) }
        decoder.primeForTesting(enhancementLayer: true)
        return Rig(decoder: decoder, composer: composer, primary: primary, enhancement: enhancement,
                   deliveries: deliveries)
    }

    private static func settle() async throws {
        try await waitFor(upTo: .milliseconds(300)) { false }
    }

    private static func isStrictlyIncreasing(_ frames: [Deliveries.Frame]) -> Bool {
        zip(frames, frames.dropFirst()).allSatisfy { CMTimeCompare($0.pts, $1.pts) < 0 }
    }

    // MARK: - 1. Residual switches off and on mid-title

    @Test("an RPU that disables the residual mid-title composes base-only for those frames, FEL resumes after, nothing fails")
    func residualDisabledMidTitleThenResumes() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        var noResidual = Self.params(); noResidual.flags.insert(.disableResidual)
        // Frames 3...5 carry an RPU with no NLQ (what a FEL to P8-shaped switch looks like to the kernel).
        let count = 9
        var bases: [CVPixelBuffer] = []
        for i in 0..<count {
            let residualOff = (3...5).contains(i)
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)),
                                        params: residualOff ? noResidual : Self.params(),
                                        displayMetadataNAL: nil)
            let bl = try Self.baseLayer(), el = try Self.enhancementLayer()
            bases.append(bl)
            r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { r.deliveries.count == count }

        let pairs = r.composer.pairs
        #expect(pairs.count == count, "every frame still goes through the composer, which does the base-only mapping")
        for (i, base) in bases.enumerated() {
            let flags = pairs.first { $0.base === base }?.flags
            #expect(flags?.contains(.disableResidual) == (3...5).contains(i), "frame \(i)")
        }
        #expect(r.composer.pairs.allSatisfy { CVPixelBufferGetWidth($0.enhancement) == 32 }, "the EL is paired, the kernel flag decides")
        #expect(r.decoder.composedFrameCount == count, "no composition failed")
        #expect(r.decoder.streamClassificationForTesting == .fel, "no route change")
        #expect(r.decoder.engagesEnhancementLayerForTesting())
        let state = r.decoder.stateSnapshotForTesting
        #expect(state.enhancementEngaged && state.blQueueCount == 0 && state.elQueueCount == 0)
        #expect(Self.isStrictlyIncreasing(r.deliveries.all))
    }

    // MARK: - 2. MEL, and a title whose first RPUs say nothing

    @Test("MEL and an unclassified el_type each log one line naming the reason and the native-route fallback")
    func melAndUnknownLogLines() {
        func decide(elType: String?, geometry: DualLayerRouteDecision.Geometry? = nil) -> DualLayerRouteDecision {
            DualLayerRouteDecision.decide(
                codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
                preferDualLayerDolbyVision: true, isLive: false, isSourceSeekable: true,
                canHardwareDecode: { true }, elType: elType,
                geometry: geometry ?? .init(width: 3840, height: 2160, frameRate: 24000.0 / 1001.0))
        }
        #expect(decide(elType: "MEL").logLine
                == "[AetherEngine] DV P7 dual-layer route: not taken (el_type=MEL, nothing to compose), keeps the native route (8.1 where the display takes Dolby Vision)")
        #expect(decide(elType: nil).logLine
                == "[AetherEngine] DV P7 dual-layer route: not taken (el_type unknown, no enhancement layer classified in the first RPU), keeps the native route (8.1 where the display takes Dolby Vision)")
        // The el_type is judged before the budget, so a MEL or unclassified 4K60 still says MEL / unknown:
        // the budget only ever speaks about FEL.
        let uhd60 = DualLayerRouteDecision.Geometry(width: 3840, height: 2160, frameRate: 60)
        #expect(decide(elType: "MEL", geometry: uhd60) == .notTaken(.melEnhancementLayer))
        #expect(decide(elType: nil, geometry: uhd60) == .notTaken(.enhancementLayerTypeUnknown))
    }

    @Test("first RPUs that cannot be classified leave the stream undetermined and the base layer playing; the first definitive RPU then decides")
    func unclassifiableFirstRPUsThenFEL() async throws {
        let decoder = DualLayerVideoDecoder(composer: RecordingComposer())
        let deliveries = Deliveries()
        decoder.onFrame = { buffer, pts, _ in deliveries.record(buffer, pts) }
        defer { decoder.close() }
        let undetermined = DoviRpuConverter.DualLayerPacketResult(
            elPacket: nil, rpuData: nil, rpuParams: nil, isFEL: false, isMEL: false, success: false)
        for _ in 0..<5 { decoder.classifyPacketResultForTesting(undetermined) }
        #expect(decoder.streamClassificationForTesting == .undetermined)
        #expect(!decoder.engagesEnhancementLayerForTesting())

        // Undetermined means no enhancement decoder: frames are delivered as their base layer.
        let bl = try Self.baseLayer()
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(0), hdr10Data: nil)
        try await waitFor { deliveries.count == 1 }
        #expect(deliveries.all.first?.buffer === bl)

        let fel = DoviRpuConverter.DualLayerPacketResult(
            elPacket: nil, rpuData: nil, rpuParams: nil, isFEL: true, isMEL: false, success: true)
        decoder.classifyPacketResultForTesting(fel)
        #expect(decoder.streamClassificationForTesting == .fel)
        #expect(decoder.engagesEnhancementLayerForTesting())
    }

    // MARK: - 3. Damaged, missing and late enhancement layers

    @Test("an enhancement layer missing for some base-layer frames costs those frames their residual, in order, with bounded waiting; pairing recovers")
    func missingEnhancementLayersMidStream() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let missing: Set<Int> = [3, 7, 8]
        let count = 12
        var bases: [CVPixelBuffer] = [], enhancements: [Int: CVPixelBuffer] = [:]
        for i in 0..<count {
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            let bl = try Self.baseLayer()
            bases.append(bl)
            if !missing.contains(i) {
                let el = try Self.enhancementLayer()
                enhancements[i] = el
                r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            }
            r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
            let s = r.decoder.stateSnapshotForTesting
            #expect(s.blQueueCount <= DualLayerVideoDecoder.maxLayerSkewFrames, "the wait for a missing EL is bounded")
        }
        try await waitFor { r.deliveries.count == count }
        let delivered = r.deliveries.all
        #expect(Self.isStrictlyIncreasing(delivered), "no frame lost, none out of order")
        let pairs = r.composer.pairs
        #expect(pairs.count == count - missing.count)
        for pair in pairs {
            let i = try #require(bases.firstIndex { $0 === pair.base })
            #expect(pair.enhancement === enhancements[i], "frame \(i) paired with its own picture's EL")
        }
        for i in missing { #expect(!pairs.contains { $0.base === bases[i] }, "frame \(i) goes out as its base layer") }
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
    }

    @Test("a long run of undecodable enhancement-layer frames (longer than the skew bound) neither deadlocks nor poisons the frames after it")
    func longEnhancementLayerOutage() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let outage = 2..<10
        let count = 14
        var bases: [CVPixelBuffer] = [], enhancements: [Int: CVPixelBuffer] = [:]
        for i in 0..<count {
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            let bl = try Self.baseLayer()
            bases.append(bl)
            if !outage.contains(i) {
                let el = try Self.enhancementLayer()
                enhancements[i] = el
                r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
            }
            r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { r.deliveries.count == count }
        #expect(Self.isStrictlyIncreasing(r.deliveries.all))
        let pairs = r.composer.pairs
        #expect(pairs.count == count - outage.count)
        for pair in pairs {
            let i = try #require(bases.firstIndex { $0 === pair.base })
            #expect(pair.enhancement === enhancements[i])
        }
        let s = r.decoder.stateSnapshotForTesting
        #expect(s.blQueueCount == 0 && s.elQueueCount == 0)
    }

    @Test("an enhancement layer that arrives within the skew bound after its base layer still pairs; frames keep their order")
    func lateEnhancementLayerWithinBound() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let k = DualLayerVideoDecoder.maxLayerSkewFrames
        var bases: [CVPixelBuffer] = [], enhancements: [CVPixelBuffer] = []
        for i in 0..<k {
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            let bl = try Self.baseLayer()
            bases.append(bl)
            r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == k, "k-1 newer frames have arrived: nothing is released early")
        for i in 0..<k {
            let el = try Self.enhancementLayer()
            enhancements.append(el)
            r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
        }
        try await waitFor { r.deliveries.count == k }
        let pairs = r.composer.pairs
        #expect(pairs.count == k)
        #expect(zip(pairs, zip(bases, enhancements)).allSatisfy { $0.base === $1.0 && $0.enhancement === $1.1 })
        #expect(Self.isStrictlyIncreasing(r.deliveries.all))
    }

    @Test("an enhancement layer that arrives after its base layer was released is dropped, not queued, and the next frames pair normally")
    func enhancementLayerLaterThanBoundIsDropped() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let k = DualLayerVideoDecoder.maxLayerSkewFrames
        var bases: [CVPixelBuffer] = []
        // Frames 0...k arrive with no EL: frame 0 is released as its base layer on frame k's arrival.
        for i in 0...k {
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            let bl = try Self.baseLayer()
            bases.append(bl)
            r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === bases[0])

        let lateEL = try Self.enhancementLayer()
        r.decoder.handleEnhancementLayerFrame(elBuffer: lateEL, pts: Self.pts(0))
        #expect(r.decoder.stateSnapshotForTesting.elQueueCount == 0, "a stale EL is not held")

        var enhancements: [CVPixelBuffer] = []
        for i in 1...k {
            let el = try Self.enhancementLayer()
            enhancements.append(el)
            r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
        }
        try await waitFor { r.deliveries.count == k + 1 }
        let pairs = r.composer.pairs
        #expect(pairs.count == k)
        #expect(pairs.allSatisfy { $0.enhancement !== lateEL })
        #expect(zip(pairs, zip(bases.dropFirst(), enhancements)).allSatisfy { $0.base === $1.0 && $0.enhancement === $1.1 })
        #expect(Self.isStrictlyIncreasing(r.deliveries.all))

        // And the pipeline keeps going.
        let bl = try Self.baseLayer(), el = try Self.enhancementLayer()
        r.decoder.seedRPUForTesting(pts: Self.pts(Int64(k + 1)), params: Self.params(), displayMetadataNAL: nil)
        r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(k + 1)), hdr10Data: nil)
        r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(k + 1)))
        try await waitFor { r.deliveries.count == k + 2 }
        #expect(r.composer.pairs.last?.base === bl && r.composer.pairs.last?.enhancement === el)
    }

    // MARK: - 4. The real-time budget

    private typealias Geometry = DualLayerRouteDecision.Geometry

    private func decide(_ geometry: Geometry, elSize: (width: Int, height: Int)? = nil) -> DualLayerRouteDecision {
        DualLayerRouteDecision.decide(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true, isLive: false, isSourceSeekable: true,
            canHardwareDecode: { true }, elType: "FEL", geometry: geometry, enhancementLayerSize: elSize)
    }

    @Test("4K at 23.976, 24, 25, 29.97 and 30 is accepted", arguments: [24000.0 / 1001.0, 24.0, 25.0, 30000.0 / 1001.0, 30.0])
    func uhdAcceptedRates(rate: Double) {
        let decision = decide(Geometry(width: 3840, height: 2160, frameRate: rate))
        guard case let .taken(_, _, fraction) = decision else {
            Issue.record("UHD at \(rate) fps should be inside the budget: \(decision)"); return
        }
        #expect(fraction <= 1.0)
    }

    @Test("4K at 50, 59.94 and 60 is refused cleanly, with the fallback named in the line",
          arguments: [50.0, 60000.0 / 1001.0, 60.0])
    func uhdRefusedRates(rate: Double) throws {
        let decision = decide(Geometry(width: 3840, height: 2160, frameRate: rate))
        guard case let .notTaken(.overBudget(required, _)) = decision else {
            Issue.record("UHD at \(rate) fps should be over budget: \(decision)"); return
        }
        #expect(required > DualLayerRouteDecision.maximumPixelsPerSecond)
        let line = try #require(decision.logLine)
        #expect(line.hasPrefix("[AetherEngine] DV P7 dual-layer route: not taken (over the real-time budget"))
        #expect(line.hasSuffix("keeps the native route (8.1 where the display takes Dolby Vision)"))
        #expect(!decision.isTaken)
    }

    @Test("an unknown base-layer size is refused with its own reason, after MEL and unknown el_type")
    func unknownGeometryFailsClosed() {
        for geometry in [Geometry(width: 0, height: 0, frameRate: nil), Geometry(width: 3840, height: 0, frameRate: 24),
                         Geometry(width: -1, height: 2160, frameRate: 24)] {
            let decision = decide(geometry)
            #expect(decision == .notTaken(.geometryUnknown))
            #expect(decision.logLine == "[AetherEngine] DV P7 dual-layer route: not taken (base-layer size unknown), keeps the native route (8.1 where the display takes Dolby Vision)")
            for elType in ["MEL", nil] as [String?] {
                let other = DualLayerRouteDecision.decide(
                    codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
                    preferDualLayerDolbyVision: true, isLive: false, isSourceSeekable: true,
                    canHardwareDecode: { true }, elType: elType, geometry: geometry)
                #expect(other == .notTaken(elType == nil ? .enhancementLayerTypeUnknown : .melEnhancementLayer))
            }
        }
    }

    @Test("the budget is a closed bound: exactly 311.04 Mpx/s is in, the next representable rate above it is out")
    func exactBudgetBoundary() {
        // 1080p with the assumed quarter-area EL needs 2073600 * 1.25 * fps: exactly the budget at 120 fps.
        let atLimit = Geometry(width: 1920, height: 1080, frameRate: 120)
        #expect(DualLayerRouteDecision.requiredPixelsPerSecond(geometry: atLimit) == DualLayerRouteDecision.maximumPixelsPerSecond)
        #expect(decide(atLimit).isTaken)
        #expect(decide(Geometry(width: 1920, height: 1080, frameRate: 120.0.nextUp)) == .notTaken(.overBudget(
            requiredPixelsPerSecond: DualLayerRouteDecision.requiredPixelsPerSecond(
                geometry: Geometry(width: 1920, height: 1080, frameRate: 120.0.nextUp)),
            geometry: Geometry(width: 1920, height: 1080, frameRate: 120.0.nextUp))))
        // The same bound reached with the EL stated 1:1 (two full 1080p layers) at 75 fps.
        let fullEL = (width: 1920, height: 1080)
        let at75 = Geometry(width: 1920, height: 1080, frameRate: 75)
        #expect(DualLayerRouteDecision.requiredPixelsPerSecond(geometry: at75, enhancementLayerSize: fullEL)
                == DualLayerRouteDecision.maximumPixelsPerSecond)
        #expect(decide(at75, elSize: fullEL).isTaken)
        #expect(!decide(Geometry(width: 1920, height: 1080, frameRate: 75.0.nextUp), elSize: fullEL).isTaken)
    }

    @Test("an enhancement layer at full resolution (1:1) doubles the need: UHD24 is refused, UHD at 15 fps is the 1:1 limit")
    func fullResolutionEnhancementLayer() {
        let uhd = Geometry(width: 3840, height: 2160, frameRate: 24)
        #expect(decide(uhd).isTaken, "the assumed quarter-area EL fits at 24 fps")
        #expect(!decide(uhd, elSize: (3840, 2160)).isTaken, "398 Mpx/s needed")
        let uhd15 = Geometry(width: 3840, height: 2160, frameRate: 15)
        #expect(decide(uhd15, elSize: (3840, 2160)).isTaken)
        // An EL smaller than a quarter makes more room, never less.
        #expect(DualLayerRouteDecision.requiredPixelsPerSecond(geometry: uhd, enhancementLayerSize: (960, 540))
                < DualLayerRouteDecision.requiredPixelsPerSecond(geometry: uhd))
    }

    @Test("odd and non-UHD sizes are budgeted by their exact pixel count, not rounded to a tier")
    func oddSizes() {
        // One pixel more than UHD on each axis at the 30 fps ceiling tips it over.
        #expect(decide(Geometry(width: 3840, height: 2160, frameRate: 30)).isTaken)
        #expect(!decide(Geometry(width: 3841, height: 2161, frameRate: 30)).isTaken)
        // DCI 4K (4096x2160): in at 24, out at 30.
        #expect(decide(Geometry(width: 4096, height: 2160, frameRate: 24)).isTaken)
        #expect(!decide(Geometry(width: 4096, height: 2160, frameRate: 30)).isTaken)
        let odd = Geometry(width: 1921, height: 1081, frameRate: 24)
        #expect(DualLayerRouteDecision.requiredPixelsPerSecond(geometry: odd) == Double(1921 * 1081) * 1.25 * 24)
        // The enhancement layer's own odd size is taken as stated.
        #expect(DualLayerRouteDecision.requiredPixelsPerSecond(geometry: odd, enhancementLayerSize: (961, 541))
                == Double(1921 * 1081 + 961 * 541) * 24)
    }

    // MARK: - 5. 23.976 against 24: 1001-based timebases

    @Test("canonical keys of 23.976 frames in 1/24000, 1001/24000, 1/1000 and 1/90000 timebases never get within the jitter of a neighbour, and agree across timebases")
    func timebaseKeysAt2397() {
        let tolerance = FrameSideDataRing.jitterToleranceTicks
        let timebases: [(AVRational, (Int64) -> Int64)] = [
            (AVRational(num: 1, den: 24000), { $0 * 1001 }),
            (AVRational(num: 1001, den: 24000), { $0 }),
            (AVRational(num: 1, den: 1000), { Int64((Double($0) * 1001.0 / 24.0).rounded()) }),
            (AVRational(num: 1, den: 90000), { Int64((Double($0) * 3753.75).rounded()) }),
        ]
        let frames: Int64 = 86_400  // one hour of 23.976
        var previous = [Int64](repeating: Int64.min, count: timebases.count)
        for n in 0..<frames {
            let keys = timebases.map { DualLayerVideoDecoder.canonicalKey(rawPTS: $0.1(n), timeBase: $0.0) }
            for (i, key) in keys.enumerated() {
                if n > 0 {
                    let gap = key - previous[i]
                    guard gap > 2 * tolerance else {
                        Issue.record("timebase \(i): frames \(n - 1) and \(n) are only \(gap) ticks apart"); return
                    }
                }
                previous[i] = key
            }
            // The same frame stamped in a coarser or finer timebase still pairs.
            for k in keys.dropFirst() where !FrameSideDataRing.isWithinJitter(keys[0], k) {
                Issue.record("frame \(n): keys \(keys) differ by more than the pairing jitter"); return
            }
        }
        // The exact 1001 grid is 3753.75 ticks per frame: rounding gives only 3753 or 3754 spacing.
        #expect(DualLayerVideoDecoder.canonicalKey(rawPTS: 1001, timeBase: AVRational(num: 1, den: 24000)) == 3754)
        #expect(DualLayerVideoDecoder.canonicalKey(rawPTS: 2002, timeBase: AVRational(num: 1, den: 24000)) == 7508)
        #expect(DualLayerVideoDecoder.canonicalKey(rawPTS: 3003, timeBase: AVRational(num: 1, den: 24000)) == 11261)
    }

    @Test("at 23.976 a seek realigns on the right picture: an early neighbour's enhancement layer is never paired with the base layer, even stamped in milliseconds")
    func seekRealignmentAt2397() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        // Pre-seek: a later stretch, left half-paired.
        for i in 100..<103 {
            r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.enhancementLayer(), pts: Self.pts2397(Int64(i)))
        }
        r.decoder.handleBaseLayerFrame(baseBuffer: try Self.baseLayer(), pts: Self.pts2397(103), hdr10Data: nil)
        r.decoder.flush()
        r.deliveries.setMarker()

        // Seek back to frame 50. The EL decoder ran ahead: frame 51's EL (in ms, as a 1/1000 stream would
        // stamp it) comes before frame 50's base layer.
        func ms(_ frame: Int64) -> CMTime { CMTime(value: Int64((Double(frame) * 1001.0 / 24.0).rounded()), timescale: 1000) }
        var bases: [CVPixelBuffer] = [], enhancements: [CVPixelBuffer] = []
        for i in 50..<56 {
            r.decoder.seedRPUForTesting(pts: Self.pts2397(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            bases.append(try Self.baseLayer()); enhancements.append(try Self.enhancementLayer())
        }
        r.decoder.handleEnhancementLayerFrame(elBuffer: enhancements[1], pts: ms(51))
        r.decoder.handleBaseLayerFrame(baseBuffer: bases[0], pts: Self.pts2397(50), hdr10Data: nil)
        r.decoder.handleEnhancementLayerFrame(elBuffer: enhancements[0], pts: ms(50))
        for i in 1..<6 {
            if i != 1 { r.decoder.handleEnhancementLayerFrame(elBuffer: enhancements[i], pts: ms(Int64(50 + i))) }
            r.decoder.handleBaseLayerFrame(baseBuffer: bases[i], pts: Self.pts2397(Int64(50 + i)), hdr10Data: nil)
        }
        try await waitFor { r.deliveries.afterMarker.count == 6 }
        let delivered = r.deliveries.afterMarker
        #expect(CMTimeCompare(try #require(delivered.first).pts, Self.pts2397(50)) == 0, "the first picture after the seek is the target picture, not its neighbour")
        #expect(zip(delivered, bases).allSatisfy { $0.buffer === $1 })
        #expect(delivered.enumerated().allSatisfy { CMTimeCompare($0.element.pts, Self.pts2397(Int64(50 + $0.offset))) == 0 })
        let pairs = r.composer.pairs
        #expect(pairs.count == 6)
        for pair in pairs {
            let i = try #require(bases.firstIndex { $0 === pair.base })
            #expect(pair.enhancement === enhancements[i], "frame \(50 + i) paired with another frame's EL (off by one)")
        }
    }

    // MARK: - 6. Seek edge cases

    @Test("a seek back to 0 replays timestamps the pre-seek run already settled, and they pair: nothing is dropped as stale")
    func seekBackToZero() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        // Play the first frames from the start, as a fresh load does.
        for i in 0..<4 {
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.enhancementLayer(), pts: Self.pts(Int64(i)))
            r.decoder.handleBaseLayerFrame(baseBuffer: try Self.baseLayer(), pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { r.deliveries.count == 4 }
        // Seek away and back to the beginning (two flushes), then replay with the EL first.
        r.decoder.flush()
        r.decoder.flush()
        r.deliveries.setMarker()
        var bases: [CVPixelBuffer] = []
        for i in 0..<4 {
            r.decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: Self.params(), displayMetadataNAL: nil)
            let bl = try Self.baseLayer()
            bases.append(bl)
            r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.enhancementLayer(), pts: Self.pts(Int64(i)))
            r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
        }
        try await waitFor { r.deliveries.afterMarker.count == 4 }
        let after = r.deliveries.afterMarker
        #expect(after.first?.pts == .zero, "the picture at time 0 is delivered")
        #expect(zip(after, bases).allSatisfy { $0.buffer === $1 })
        #expect(r.composer.pairs.count == 8, "all eight frames, both passes, were composed")
        #expect(r.decoder.composedFrameCount == 8)
    }

    @Test("a seek next to the end of the file composes the last pair, and the end-of-stream flush leaves a clean, repeatable state")
    func seekNearEndOfFile() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let last: Int64 = 172_000  // ~2 h at 24 fps
        r.decoder.flush()          // the seek
        r.deliveries.setMarker()
        for i in (last - 1)...last {
            r.decoder.seedRPUForTesting(pts: Self.pts(i), params: Self.params(), displayMetadataNAL: nil)
            r.decoder.handleBaseLayerFrame(baseBuffer: try Self.baseLayer(), pts: Self.pts(i), hdr10Data: nil)
            r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.enhancementLayer(), pts: Self.pts(i))
        }
        try await waitFor { r.deliveries.afterMarker.count == 2 }
        #expect(CMTimeCompare(try #require(r.deliveries.afterMarker.last).pts, Self.pts(last)) == 0)
        r.decoder.flush()
        r.decoder.flush()
        let s = r.decoder.stateSnapshotForTesting
        #expect(s.blQueueCount == 0 && s.elQueueCount == 0 && s.rpuCacheCount == 0 && !s.draining)
        #expect(r.primary.flushCount == 3 && r.enhancement.flushCount == 3 && r.composer.flushCount == 3)
    }

    @Test("a scrub burst of seeks flushes both sessions and the composer every time, and only the last position's frames come out")
    func scrubBurst() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let seeks = 40
        let epoch = r.decoder.feedEpoch
        for s in 0..<seeks {
            let base = Int64(s * 1000)
            // Each position leaves a base layer waiting for its EL and an EL waiting for its base layer.
            r.decoder.seedRPUForTesting(pts: Self.pts(base), params: Self.params(), displayMetadataNAL: nil)
            r.decoder.handleBaseLayerFrame(baseBuffer: try Self.baseLayer(), pts: Self.pts(base), hdr10Data: nil)
            r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.enhancementLayer(), pts: Self.pts(base + 7))
            r.decoder.flush()
        }
        r.deliveries.setMarker()
        #expect(r.decoder.feedEpoch == epoch + UInt64(seeks))
        #expect(r.primary.flushCount == seeks && r.enhancement.flushCount == seeks && r.composer.flushCount == seeks)
        let drained = r.decoder.stateSnapshotForTesting
        #expect(drained.blQueueCount == 0 && drained.elQueueCount == 0 && drained.rpuCacheCount == 0)

        // The landing position: a stray EL from the previous position's key space must not pair.
        let landing = Int64(seeks * 1000)
        let bl = try Self.baseLayer(), el = try Self.enhancementLayer()
        r.decoder.seedRPUForTesting(pts: Self.pts(landing), params: Self.params(), displayMetadataNAL: nil)
        r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(landing))
        r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(landing), hdr10Data: nil)
        try await waitFor { r.deliveries.afterMarker.count == 1 }
        try await Self.settle()
        let after = r.deliveries.afterMarker
        #expect(after.count == 1 && after.first?.buffer === bl)
        #expect(r.composer.pairs.count == 1 && r.composer.pairs.first?.enhancement === el)
    }

    // MARK: - 7. Display without Dolby Vision

    @Test("the three route gates take no display input and agree for a FEL P7 title, so a non-DV display does not change the route today")
    func routeGatesIgnoreTheDisplay() {
        // `DualLayerRouteDecision.decide`, `VideoRoutingPolicy.requiresSoftwarePath` and
        // `SoftwarePlaybackHost.shouldUseDualLayerDecoder` have no `DisplayCapabilities` parameter:
        // the load decides the route from the stream, the options and the decoder capability only.
        let decision = decide(Geometry(width: 3840, height: 2160, frameRate: 24000.0 / 1001.0))
        let software = VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
            dvProfile: 7, dolbyVisionHandling: .automatic, preferDualLayerDolbyVision: true,
            canHardwareDecode: { true }, elType: "FEL")
        let dual = SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic)
        #expect(decision.isTaken && software && dual)
        // And they fall back together.
        let melDecision = DualLayerRouteDecision.decide(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true, isLive: false, isSourceSeekable: true,
            canHardwareDecode: { true }, elType: "MEL",
            geometry: Geometry(width: 3840, height: 2160, frameRate: 24))
        #expect(!melDecision.isTaken)
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
            dvProfile: 7, dolbyVisionHandling: .automatic, preferDualLayerDolbyVision: true,
            canHardwareDecode: { true }, elType: "MEL"))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "MEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic))
    }
}
#endif
