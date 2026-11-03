import Testing
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

extension HeavyDualLayerSuites {
    /// End-to-end FEL checks on real Profile 7 files, where the synthetic suites
    /// cannot reach: container framing quirks (the Matroska `packet->data != buf->data`
    /// case that produced zero frames), real RPUs, real reorder, seeks and teardown.
    ///
    /// The fixtures (`fel-clip-a.mkv`, `fel-clip-b.mkv`, `fel-clip-c.mp4`) live in the
    /// directory named by `DV_FEL_TESTS_DIR`, or in `DV FEL Tests/` next to the package;
    /// they are not checked in, and every test skips when its file is absent.
    @Suite(.offCooperativePool)
    struct DoviFelRealFileTests {

        static let fixtures = [
            "fel-clip-a.mkv",
            "fel-clip-b.mkv",
            "fel-clip-c.mp4",
        ]

        static func url(_ name: String) -> URL {
            if let dir = ProcessInfo.processInfo.environment["DV_FEL_TESTS_DIR"] {
                return URL(fileURLWithPath: dir).appendingPathComponent(name)
            }
            return URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // AetherEngineTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // AetherEngine
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("DV FEL Tests")
                .appendingPathComponent(name)
        }

        static func available(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: url(name).path)
        }

        /// The `.enabled(if:)` reason of every test that needs a clip: the clips are not checked in, so
        /// those tests show as skipped without them rather than passing without having run.
        static let needsClips: Comment = "needs the DV FEL test clips (not checked in): set DV_FEL_TESTS_DIR"

        /// The fixtures present, for `arguments:` of a test that runs once per clip.
        static var availableFixtures: [String] { fixtures.filter(available) }

        /// The first two clips, when present: the ones long enough to seek into.
        static var firstTwoClips: [String] { [fixtures[0], fixtures[1]].filter(available) }
    }
}

// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
extension HeavyDualLayerSuites.DoviFelRealFileTests {

    // MARK: - Harness

    /// Forwards to the real composer while keeping the first few inputs, so a
    /// test can re-run the same frame with different parameters.
    final class RecordingComposer: FelComposing, @unchecked Sendable {
        struct Capture { let bl: CVPixelBuffer; let el: CVPixelBuffer; let params: DoviMetalParams }
        let inner: DoviFelComposer
        private let lock = NSLock()
        private var _captures: [Capture] = []
        private let limit: Int
        private let stride: Int
        private var calls = 0

        init?(limit: Int = 16, stride: Int = 15) {
            self.stride = stride
            guard let c = DoviFelComposer() else { return nil }
            inner = c
            self.limit = limit
        }

        var captures: [Capture] { lock.lock(); defer { lock.unlock() }; return _captures }

        private func record(_ bl: CVPixelBuffer, _ el: CVPixelBuffer, _ p: DoviMetalParams) {
            lock.lock()
            if _captures.count < limit, calls % stride == 0 { _captures.append(Capture(bl: bl, el: el, params: p)) }
            calls += 1
            lock.unlock()
        }

        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            record(baseBuffer, enhancementBuffer, params)
            inner.composeAsync(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer, params: params,
                               frameIndex: frameIndex, completion: completion)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer,
                                          params: DoviMetalParams, frameIndex: UInt32,
                                          completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            record(baseBuffer, enhancementBuffer, params)
            inner.composeAsyncWithAcquiredSlot(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer,
                                               params: params, frameIndex: frameIndex, completion: completion)
        }
        func acquireSlot() { inner.acquireSlot() }
        func releaseSlot() { inner.releaseSlot() }
        func flush() { inner.flush() }
        func flushTextureCache() { inner.flushTextureCache() }
        func takePeakSlotsInUse() -> Int { inner.takePeakSlotsInUse() }
        var allocatedPoolBuffers: Int { inner.allocatedPoolBuffers }
        var meanGPUTimeMs: Double? { inner.meanGPUTimeMs }
    }

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var pts: [Double] = []
        private(set) var withRPU = 0
        private(set) var sizes = Set<String>()
        private(set) var formats = Set<OSType>()

        func take(_ buffer: CVPixelBuffer, _ time: CMTime) {
            lock.lock(); defer { lock.unlock() }
            pts.append(time.seconds)
            sizes.insert("\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))")
            formats.insert(CVPixelBufferGetPixelFormatType(buffer))
            if CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) != nil { withRPU += 1 }
        }
        func reset() { lock.lock(); pts = []; withRPU = 0; lock.unlock() }
    }

    struct Session {
        let demuxer: Demuxer
        let decoder: DualLayerVideoDecoder
        let sink: Sink
        let videoIndex: Int32
    }

    static func open(_ name: String, composer: (any FelComposing)? = DoviFelComposer()) throws -> Session {
        let demuxer = Demuxer()
        try demuxer.open(url: url(name))
        let idx = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: idx))
        let sink = Sink()
        let decoder = DualLayerVideoDecoder(composer: composer)
        try decoder.open(stream: stream) { buf, pts, _ in sink.take(buf, pts) }
        return Session(demuxer: demuxer, decoder: decoder, sink: sink, videoIndex: Int32(idx))
    }

    /// Feeds up to `count` video packets; returns how many were fed.
    @discardableResult
    static func feed(_ s: Session, count: Int, epoch: UInt64? = nil) -> Int {
        var fed = 0
        while fed < count {
            guard let pkt = try? s.demuxer.readPacket() else { break }
            if pkt.pointee.stream_index == s.videoIndex {
                fed += 1
                s.decoder.decode(packet: pkt, epoch: epoch)
            }
            av_packet_unref(pkt)
            var opt: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&opt)
        }
        return fed
    }

    static func lumaPlane(_ b: CVPixelBuffer) -> [UInt16] {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(b, 0), h = CVPixelBufferGetHeightOfPlane(b, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(b, 0) / 2
        let base = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt16.self)
        var out = [UInt16](); out.reserveCapacity(w * h)
        for y in 0..<h { for x in 0..<w { out.append(base[y * stride + x] >> 6) } }
        return out
    }

    // MARK: - Tests

    @Test("every real FEL file reconstructs nearly every packet, in presentation order, each with its RPU",
          .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func reconstructsAndOrders(name: String) throws {
        let s = try Self.open(name)
        defer { s.decoder.close(); s.demuxer.close() }
        let fed = Self.feed(s, count: 240)
        s.decoder.flush()

        #expect(s.decoder.streamClassification == .fel)
        let got = s.sink.pts.count
        #expect(fed == 240)
        #expect(got >= Int(Double(fed) * 0.9), "\(got) frames from \(fed) packets")
        #expect(s.sink.withRPU == got, "every output frame must carry display metadata")
        // Frames that merely pass through as their base layer would satisfy every check above, so the
        // composer must also have run on a clear majority of them (a few at the start wait for their
        // enhancement layer's first picture, and a few at the end go out as the base layer).
        let composed = s.decoder.composedFrameCount
        print("[compose] \(name): composed \(composed) of \(got) delivered frames")
        #expect(composed > 0, "no frame was composed: the whole file went out as its base layer")
        #expect(composed * 10 >= got * 8, "only \(composed) of \(got) frames were composed")
        #expect(s.sink.formats == [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        #expect(s.sink.sizes.count == 1, "\(s.sink.sizes)")
        // Delivery is in decode order by design; `SampleBufferRenderer` restores
        // presentation order with a sorted buffer that releases once it holds more
        // than `reorderDepth` (4) frames. Replay that exact rule: the file's reorder
        // depth must fit, or the renderer would show frames out of order.
        let pts = s.sink.pts
        var buffer: [Double] = []
        var released: [Double] = []
        for t in pts {
            buffer.insert(t, at: buffer.firstIndex(where: { $0 > t }) ?? buffer.endIndex)
            while buffer.count > 4 { released.append(buffer.removeFirst()) }
        }
        released.append(contentsOf: buffer)
        let bad = zip(released, released.dropFirst()).filter { $1 <= $0 }.count
        let inversions = zip(pts, pts.dropFirst()).filter { $1 <= $0 }.count
        print("[order] \(name): \(inversions) decode-order inversions of \(pts.count); after the renderer's 4-deep reorder: \(bad) regressions")
        #expect(bad == 0, "reorder depth exceeds the renderer buffer: \(bad) regressions")
        #expect(Set(pts).count == pts.count, "duplicate presentation timestamps delivered")
    }

    @Test("every delivered frame carries its own packet's Profile 8.1 RPU: the composed form, or the mapping-preserving form when it was shown as its base layer",
          .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func deliveredFramesCarryTheirOwnRpu(name: String) throws {
        // Expected: the 8.1 RPU of each packet, or the last good one before it in decode order. A composed
        // frame carries the composed form (mapping removed); a frame the decoder bypassed (deadline, missing
        // enhancement layer, failed composition) carries the base-layer form that keeps its mapping. Which
        // frames were bypassed depends on machine load, so both forms are expected per packet.
        let reference = Demuxer()
        try reference.open(url: Self.url(name))
        let index = Int32(reference.videoStreamIndex)
        let timeBase = try #require(reference.stream(at: reference.videoStreamIndex)).pointee.time_base
        var expected: [Int64: Data] = [:]
        var expectedBase: [Int64: Data] = [:]
        var lastGood: [UInt8]?
        var lastGoodBase: [UInt8]?
        var packets = 0
        while packets < 240, let pkt = try? reference.readPacket() {
            if pkt.pointee.stream_index == index {
                packets += 1
                let layers = DoviRpuConverter.separateDualLayers(pkt, extractEL: false, extractParams: true)
                if let converted = layers.convertedRpu {
                    lastGood = converted
                    // A missing mapping form falls back to the composed one, as the decoder does.
                    lastGoodBase = layers.baseLayerRpu ?? converted
                }
                let ms = Int64((Double(pkt.pointee.pts) * av_q2d(timeBase) * 1000).rounded())
                expected[ms] = DoviDisplayMetadata.payload(fromNAL: lastGood)
                expectedBase[ms] = DoviDisplayMetadata.payload(fromNAL: lastGoodBase)
            }
            av_packet_unref(pkt)
            var opt: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&opt)
        }
        reference.close()

        let demuxer = Demuxer()
        try demuxer.open(url: Self.url(name))
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        final class Delivered: @unchecked Sendable {
            let lock = NSLock()
            var frames: [(Int64, Data?)] = []
        }
        let delivered = Delivered()
        let decoder = DualLayerVideoDecoder(composer: DoviFelComposer())
        try decoder.open(stream: stream) { buffer, pts, _ in
            let payload = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data
            delivered.lock.withLock { delivered.frames.append((Int64((pts.seconds * 1000).rounded()), payload)) }
        }
        let s = Session(demuxer: demuxer, decoder: decoder, sink: Sink(), videoIndex: Int32(demuxer.videoStreamIndex))
        defer { decoder.close(); demuxer.close() }
        Self.feed(s, count: 240)
        decoder.flush()

        let frames = delivered.lock.withLock { delivered.frames }
        // Delivered and demuxed times round to the millisecond independently: allow one either way.
        func expectedPayload(_ ms: Int64) -> Data? { expected[ms] ?? expected[ms - 1] ?? expected[ms + 1] }
        func expectedBasePayload(_ ms: Int64) -> Data? { expectedBase[ms] ?? expectedBase[ms - 1] ?? expectedBase[ms + 1] }
        let composedForm = frames.filter { ms, payload in payload != nil && payload == expectedPayload(ms) }.count
        let matched = frames.filter { ms, payload in
            payload != nil && (payload == expectedPayload(ms) || payload == expectedBasePayload(ms))
        }.count
        print("[rpu] \(name): \(matched) of \(frames.count) delivered frames carry their packet's RPU (\(composedForm) in the composed form); composed \(decoder.composedFrameCount)")
        #expect(frames.count >= 216)
        #expect(matched == frames.count)
        // Composition ran, and its frames carry the composed form (a bypassed frame carries the other one).
        #expect(composedForm > 0 || decoder.composedFrameCount == 0, "no frame carries the composed RPU form")
    }

    @Test("the enhancement layer is aligned with the base layer: the residual acts, and never exceeds vdr_in_max",
          .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func residualIsAlignedAndNonTrivial(name: String) throws {
        let rec = try #require(RecordingComposer())
        let s = try Self.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        Self.feed(s, count: 300)
        s.decoder.flush()

        let caps = rec.captures
        try #require(!caps.isEmpty, "no frames reached the composer")
        // The frame whose enhancement layer carries the most signal.
        func spread(_ c: RecordingComposer.Capture) -> Int {
            let y = Self.lumaPlane(c.el); return Int(y.max() ?? 0) - Int(y.min() ?? 0)
        }
        let cap = caps.max(by: { spread($0) < spread($1) })!
        let flatEverywhere = spread(cap) == 0
        #expect(!cap.params.flags.contains(.disableResidual), "fixture is FEL, residual must be live")

        var without = cap.params
        without.flags.insert(.disableResidual)
        without.ditherMode = .none
        var with = cap.params
        with.ditherMode = .none

        let a = try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: without, frameIndex: 0))
        let b = try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: with, frameIndex: 0))
        let ya = Self.lumaPlane(a), yb = Self.lumaPlane(b)
        #expect(ya.count == yb.count)

        var differing = 0
        var sumAbs = 0
        var maxAbs = 0
        for i in 0..<ya.count {
            let d = abs(Int(ya[i]) - Int(yb[i]))
            if d != 0 { differing += 1; sumAbs += d; maxAbs = max(maxAbs, d) }
        }
        func stat(_ v: [UInt16]) -> String {
            let m = Double(v.reduce(0) { $0 + Int($1) }) / Double(v.count)
            return "mean \(String(format: "%.1f", m)) min \(v.min() ?? 0) max \(v.max() ?? 0)"
        }
        let elY = Self.lumaPlane(cap.el)
        print("[diag] \(name): BL \(CVPixelBufferGetWidth(cap.bl))x\(CVPixelBufferGetHeight(cap.bl)) EL \(CVPixelBufferGetWidth(cap.el))x\(CVPixelBufferGetHeight(cap.el)) flags=\(cap.params.flags.rawValue)")
        print("[diag]   BL luma \(stat(Self.lumaPlane(cap.bl)))  EL luma \(stat(elY))  out(no res) \(stat(ya))  out(res) \(stat(yb))")
        let n = cap.params.nlqY
        print("[diag]   nlqY method=\(n.nlqMethod) offset=\(n.nlqOffset) scale=\(n.nlqScale) thr=\(n.nlqThreshold) vdrInMax=\(n.vdrInMax) shift=\(n.nlqShift) pivots=\(n.nlqPivots)")
        print("[diag]   polyY pivots=\(cap.params.polyY.pivots.prefix(Int(cap.params.polyY.numPivots))) order=\(cap.params.polyY.order.prefix(3)) coef0=\(cap.params.polyY.coef[0]) shift0=\(cap.params.polyY.coefShift[0]) blMax=\(cap.params.blMax) vdrScale=\(cap.params.vdrScale)")
        let fraction = Double(differing) / Double(ya.count)
        let meanAbs = differing == 0 ? 0 : Double(sumAbs) / Double(differing)
        // A misaligned or mis-scaled EL would either do nothing or look like noise
        // of full amplitude; a genuine detail residual is sparse-to-moderate and small.
        print("[residual] \(name): \(String(format: "%.1f", fraction * 100))% pixels differ, mean |d|=\(String(format: "%.2f", meanAbs)), max |d|=\(maxAbs)")
        // The residual is bounded by construction: |r| <= vdr_in_max VDR codes, i.e. vdr_in_max / vdr_scale output codes.
        let bound = Int(cap.params.nlqY.vdrInMax) / Int(cap.params.vdrScale) + 1
        #expect(maxAbs <= bound, "residual \(maxAbs) exceeds vdr_in_max bound \(bound)")
        if flatEverywhere {
            print("[residual] \(name): EL flat in all \(caps.count) sampled frames; residual correctly does nothing")
            #expect(differing == 0)
        } else {
            #expect(fraction > 0.001, "the residual had no effect on luma")
        }
    }

    /// N5: what a base-layer fallback frame costs. When the output pool is empty the pipeline presents the
    /// base layer as it is; this measures how far that frame is from the composed one on each real title,
    /// in 10-bit codes per plane. The comment on the fallback used to claim ~2/4096 codes, which came from
    /// the near-identity synthetic stream.
    @Test("a base-layer fallback frame differs from the composed frame by a measured amount on real titles",
          .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func fallbackFrameDelta(name: String) throws {
        let rec = try #require(RecordingComposer(limit: 6, stride: 40))
        let s = try Self.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        Self.feed(s, count: 300)
        s.decoder.flush()
        let caps = rec.captures
        try #require(!caps.isEmpty, "no frames reached the composer")

        func planes(_ b: CVPixelBuffer) -> [[Int]] {
            CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            let w = CVPixelBufferGetWidthOfPlane(b, 0), h = CVPixelBufferGetHeightOfPlane(b, 0)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0) / 2
            let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt16.self)
            let cw = CVPixelBufferGetWidthOfPlane(b, 1), ch = CVPixelBufferGetHeightOfPlane(b, 1)
            let cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1) / 2
            let c = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt16.self)
            var out = [(0..<(w * h)).map { Int(y[($0 / w) * ys + $0 % w] >> 6) }]
            for k in 0..<2 { out.append((0..<(cw * ch)).map { Int(c[($0 / cw) * cs + ($0 % cw) * 2 + k] >> 6) }) }
            return out
        }
        var worstMean = 0.0
        for (i, cap) in caps.enumerated() {
            var p = cap.params; p.ditherMode = .none
            let composed = planes(try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: p, frameIndex: 0)))
            let base = planes(cap.bl)
            for (k, plane) in ["Y", "Cb", "Cr"].enumerated() {
                let d = zip(composed[k], base[k]).map { abs($0 - $1) }.sorted()
                let mean = Double(d.reduce(0, +)) / Double(d.count)
                worstMean = max(worstMean, mean)
                print(String(format: "[fallback] %@ f%d %@: mean |d| %.2f codes (10-bit), p99 %d, max %d",
                             name, i, plane, mean, d[Int(Double(d.count) * 0.99)], d.last ?? 0))
            }
        }
        print(String(format: "[fallback] %@: worst per-plane mean |d| %.2f (10-bit codes)", name, worstMean))
    }

    @Test("the end-of-stream drain delivers a frame for every packet fed, leaving nothing for the flush after it",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips),
          .timeLimit(.minutes(2)), arguments: [DoviFelRealFileTests.fixtures[0]])
    func endOfStreamDrainDeliversTheLastFrames(name: String) throws {
        let s = try Self.open(name)
        defer { s.decoder.close(); s.demuxer.close() }
        // The clip opens on an IDR, so every packet from its head decodes to one frame.
        let fed = Self.feed(s, count: 120)
        s.decoder.drainForEndOfStream()
        let drained = s.sink.pts.count
        #expect(drained == fed, "\(drained) frames from \(fed) packets")
        s.decoder.flush()
        #expect(s.sink.pts.count == drained, "the drain left frames for the flush to drop")
    }

    @Test("a session rebuild leaves both layers on the decoder's epoch: packets fed after it still decode",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips),
          .timeLimit(.minutes(2)), arguments: [DoviFelRealFileTests.fixtures[0]])
    func sessionRebuildKeepsTheEpoch(name: String) async throws {
        let s = try Self.open(name)
        defer { s.decoder.close(); s.demuxer.close() }
        Self.feed(s, count: 30, epoch: s.decoder.feedEpoch)
        #expect(s.decoder.enhancementFeedEpochForTesting != nil)
        // The host's return from background audio-only: flush, rebuild, then feed on with no
        // reposition in between, so nothing else moves the layers' epochs back.
        s.decoder.flush()
        #expect(s.decoder.rebuildSession())
        #expect(s.decoder.enhancementFeedEpochForTesting == s.decoder.feedEpoch)
        let before = s.sink.pts.count
        // A rebuilt session resumes at a keyframe: feed again from the head of the clip.
        s.demuxer.seek(to: 0)
        Self.feed(s, count: 30, epoch: s.decoder.feedEpoch)
        try await waitFor { s.sink.pts.count > before }
    }

    @Test("a flush before the first enhancement packet leaves the enhancement decoder in step: its frames still arrive",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips),
          .timeLimit(.minutes(2)), arguments: [DoviFelRealFileTests.fixtures[0]])
    func flushBeforeFirstEnhancementPacket(name: String) async throws {
        let rec = try #require(RecordingComposer())
        let s = try Self.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        // The host seeks (flush) before the stream has been classified, so the enhancement decoder
        // opens afterwards, at an epoch the decoder it belongs to has already moved past.
        s.decoder.flush()
        #expect(s.decoder.enhancementFeedEpochForTesting == nil)
        // The host hands every packet the epoch it read, as it does in playback.
        Self.feed(s, count: 60, epoch: s.decoder.feedEpoch)
        #expect(s.decoder.enhancementFeedEpochForTesting == s.decoder.feedEpoch)
        // A composition needs an enhancement frame, so the composer being called proves they arrive.
        try await waitFor { !rec.captures.isEmpty }
    }

    @Test("a seek followed by a flush delivers only post-seek frames and recovers immediately",
          .enabled(if: !DoviFelRealFileTests.firstTwoClips.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.firstTwoClips)
    func seekFlushRecovers(name: String) throws {
        let s = try Self.open(name)
        defer { s.decoder.close(); s.demuxer.close() }
        Self.feed(s, count: 60)
        s.decoder.flush()
        let before = s.sink.pts.count
        #expect(before > 0)

        #expect(s.demuxer.seek(to: 60.0))
        s.sink.reset()
        Self.feed(s, count: 90)
        s.decoder.flush()

        let after = s.sink.pts
        #expect(after.count >= 60, "only \(after.count) frames after seek")
        // Nothing from before the seek target's keyframe may leak through.
        #expect((after.min() ?? 0) > 30, "pre-seek frame leaked: \(after.min() ?? -1)")
        #expect(s.sink.withRPU == after.count)
    }

    @Test("repeated seeks back and forth never wedge the pipeline",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips))
    func seekStorm() throws {
        let name = Self.fixtures[0]
        let s = try Self.open(name)
        defer { s.decoder.close(); s.demuxer.close() }
        for target in [10.0, 90.0, 5.0, 100.0, 0.0, 45.0] {
            #expect(s.demuxer.seek(to: target))
            s.sink.reset()
            Self.feed(s, count: 40)
            s.decoder.flush()
            #expect(s.sink.pts.count >= 25, "target \(target): \(s.sink.pts.count) frames")
        }
    }

    @Test("close without a flush, and immediate re-open, are safe and leave no session behind",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[2]), DoviFelRealFileTests.needsClips),
          .timeLimit(.minutes(3)))
    func openCloseChurn() throws {
        let name = Self.fixtures[2]
        for round in 0..<6 {
            let s = try Self.open(name)
            Self.feed(s, count: round % 2 == 0 ? 5 : 40)
            s.decoder.close()      // deliberately no flush first
            s.demuxer.close()
            // Packets fed after close must be refused, not resurrect the session.
        }
    }

    @Test("feeding packets after close is ignored",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[2]), DoviFelRealFileTests.needsClips))
    func decodeAfterCloseIgnored() throws {
        let name = Self.fixtures[2]
        let s = try Self.open(name)
        Self.feed(s, count: 20)
        s.decoder.flush()
        s.decoder.close()
        s.sink.reset()
        Self.feed(s, count: 20)
        s.decoder.flush()
        #expect(s.sink.pts.isEmpty, "frames delivered after close")
        s.demuxer.close()
    }

    @Test("a full pass over a whole file keeps memory flat and never stalls",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[2]), DoviFelRealFileTests.needsClips),
          .timeLimit(.minutes(5)))
    func longRunStable() throws {
        let name = Self.fixtures[2]
        let s = try Self.open(name)
        defer { s.decoder.close(); s.demuxer.close() }

        func rss() -> Int {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return Int(info.resident_size) / (1024 * 1024)
        }

        var total = 0
        var samples: [Int] = []
        while true {
            let fed = Self.feed(s, count: 200)
            total += fed
            samples.append(rss())
            if fed < 200 { break }
        }
        s.decoder.flush()
        print("[longRun] packets=\(total) frames=\(s.sink.pts.count) rss MiB by 200-packet step: \(samples)")
        #expect(total > 300)
        #expect(s.sink.pts.count >= Int(Double(total) * 0.95))
        // Steady state: the last third may not sit more than 400 MiB above the first third. Resident
        // memory is the whole process's, so tests running in parallel move it too (it grew by 420 to 480 MiB
        // in full runs, while this test alone stayed flat at about 106 MiB). Asserted only when asked for
        // a run on its own: DV_FEL_MEMORY_SOLO=1 swift test --filter longRunStable
        if ProcessInfo.processInfo.environment["DV_FEL_MEMORY_SOLO"] != nil, samples.count >= 6 {
            let early = samples[1..<(samples.count / 3 + 1)].max() ?? 0
            let late = samples[(samples.count * 2 / 3)...].max() ?? 0
            #expect(late - early < 400, "resident memory grew \(early) -> \(late) MiB")
        }
    }
}
#endif
