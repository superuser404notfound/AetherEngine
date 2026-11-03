import Foundation
import Combine
import Testing
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("H264 VOD configuration compatibility", .serialized, .offCooperativePool, .timeLimit(.minutes(2)))
struct H264ConfigurationTrackerTests {
    private let sps = Self.hex("6764001facd9405005bb016a02040280000003008000001e078c18cb")
    private let changed = Self.hex("6764001facd9404c057fbc05a828282a000003000200000300781e30632c")
    private let pps: [UInt8] = [0x68, 0xef, 0xbc, 0xb0]
    private let idr: [UInt8] = [0x65, 0x88, 0x84, 0]
    private static func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    private func avcc() -> [UInt8] {
        [1, 100, 0, 31, 255, 225, 0, UInt8(sps.count)] + sps + [1, 0, UInt8(pps.count)] + pps
    }
    private func packet(_ nals: [[UInt8]], size: Int = 4) -> [UInt8] {
        nals.flatMap { nal in
            (0..<size).reversed().map { UInt8((nal.count >> ($0 * 8)) & 255) } + nal
        }
    }
    private func observe(_ tracker: inout H264ConfigurationTracker, _ nals: [[UInt8]], size: Int = 4) -> H264ConfigurationTracker.Mismatch? {
        packet(nals, size: size).withUnsafeBufferPointer { tracker.observe($0, lengthSize: size) }
    }

    @Test("Repeated sets and ordinary IDRs keep the native path")
    func repeatedSets() throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc()))
        for _ in 0..<5 { #expect(observe(&tracker, [sps, pps, idr]) == nil) }
        #expect(observe(&tracker, [idr]) == nil)
    }
    @Test("Same-ID parameter changes are judged by the slice's actual references", arguments: [1, 2, 4])
    func activeChange(size: Int) throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc()))
        let result = observe(&tracker, [changed, pps, idr], size: size)
        #expect(result?.width == 1216)
        #expect(result?.height == 684)
        #expect(result?.spsID == 0)
        #expect(result?.ppsID == 0)
    }
    @Test("Announcing an unused PPS does not reroute playback")
    func unusedPictureSet() throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc()))
        #expect(observe(&tracker, [[0x68, 0x58], idr]) == nil) // PPS 1 refers to SPS 0; slice uses PPS 0
    }
    @Test("A changed set is retained until an IDR actually uses it")
    func separateSets() throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc()))
        #expect(observe(&tracker, [changed]) == nil)
        #expect(observe(&tracker, [[0x41, 0x9a, 0, 0]]) == nil)
        #expect(observe(&tracker, [idr]) != nil)
        #expect(observe(&tracker, [sps, idr]) == nil)
    }
    @Test("NAL ordering does not apply future parameter sets to an earlier slice")
    func nalOrdering() throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc()))
        #expect(observe(&tracker, [idr, changed]) == nil)
        #expect(observe(&tracker, [idr]) != nil)
    }
    @Test("Truncated lengths and malformed parameter sets cannot poison later decisions")
    func malformedInput() throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc()))
        for tail: [UInt8] in [[0xff,0xff,0xff,0xff], [0,0], [0,0,0,0], [0,0,0,2,0xe7,0]] {
            let bytes = packet([changed]) + tail
            #expect(bytes.withUnsafeBufferPointer { tracker.observe($0, lengthSize: 4) } == nil)
            #expect(observe(&tracker, [idr]) == nil)
        }
        #expect(observe(&tracker, [[0x67], idr]) == nil)
        #expect(observe(&tracker, [idr]) == nil)
        #expect(H264ConfigurationTracker(avcC: Array(avcc().dropLast())) == nil)
        #expect(H264ConfigurationTracker(avcC: [1,2,3]) == nil)
    }
    // #785 follow-up: in-band set pairs taken from x264 encodes joined with a stream copy. On macOS the
    // native route played the VUI, level and PPS changes through (739 to 743 frames over 30 s) and
    // froze at the profile change, as at a resolution change.
    private static let baselineSPS = hex("6742c01fda014016ec05a810100a000003000200000300601e306540")
    private static let baselinePPS = hex("68ce0fc8")
    private func avcc(sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        [1, sps[1], sps[2], sps[3], 255, 225, 0, UInt8(sps.count)] + sps + [1, 0, UInt8(pps.count)] + pps
    }
    @Test("A set that differs only in VUI, level or PPS keeps the native route", arguments: [
        ("6742c01fda014016ec05a810102a000003000200000300601e306540", "68ce0fc8"),
        ("6742c029da014016ec0440000003004000000c03c60ca8", "68ce0fc8"),
        ("6742c01fda014016ec05a810100a000003000200000300601e306540", "68ce0fcb"),
    ])
    func decoderCompatibleChange(sps: String, pps: String) throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc(sps: Self.baselineSPS, pps: Self.baselinePPS)))
        #expect(observe(&tracker, [Self.hex(sps), Self.hex(pps), idr]) == nil)
        #expect(observe(&tracker, [idr]) == nil)
    }
    @Test("A profile change at the same size still takes the compatible decoder")
    func profileChange() throws {
        var tracker = try #require(H264ConfigurationTracker(avcC: avcc(sps: Self.baselineSPS, pps: Self.baselinePPS)))
        let high = Self.hex("6764001facb402802dd80b50202014000003000400000300c03c60ca80")
        let result = observe(&tracker, [high, Self.hex("68ee0fcb"), idr])
        #expect(result?.width == 1280)
        #expect(result?.height == 720)
    }
    @Test("The decoder signature ignores VUI and level but not size or profile")
    func decoderSignature() throws {
        let base = try #require(H264SPS.decoderSignature(fromNAL: Self.baselineSPS))
        #expect(H264SPS.decoderSignature(fromNAL: Self.hex("6742c01fda014016ec05a810102a000003000200000300601e306540")) == base)
        #expect(H264SPS.decoderSignature(fromNAL: Self.hex("6742c029da014016ec0440000003004000000c03c60ca8")) == base)
        #expect(H264SPS.decoderSignature(fromNAL: Self.hex("6764001facb402802dd80b50202014000003000400000300c03c60ca80")) != base)
        #expect(H264SPS.decoderSignature(fromNAL: sps) != H264SPS.decoderSignature(fromNAL: changed))
    }
    @Test("The new media verdict respects explicit route, host and once-only constraints")
    func escalationPolicy() {
        let domain = SoftwarePathEscalation.videoConfigurationErrorDomain
        #expect(SoftwarePathEscalation.shouldEscalate(errorDomain: domain,
            availability: .init(alreadyEscalated: false, preferredDecodePath: .automatic, nativeRemoteHLS: false)))
        for a in [
            SoftwarePathEscalation.Availability(alreadyEscalated: true, preferredDecodePath: .automatic, nativeRemoteHLS: false),
            .init(alreadyEscalated: false, preferredDecodePath: .software, nativeRemoteHLS: false),
            .init(alreadyEscalated: false, preferredDecodePath: .automatic, nativeRemoteHLS: false, hostAllowsEscalation: false),
            .init(alreadyEscalated: false, preferredDecodePath: .automatic, nativeRemoteHLS: true)
        ] { #expect(!SoftwarePathEscalation.shouldEscalate(errorDomain: domain, availability: a)) }
    }
    @Test("A reload retains the pending user seek instead of the producer or frozen clock")
    func pendingSeekPosition() {
        #expect(AetherEngine.rebuildPosition(state: .seeking, clock: 10, underReconstruction: nil, pendingSeek: 585.9) == 585.9)
        #expect(AetherEngine.rebuildPosition(state: .paused, clock: 10, underReconstruction: nil, pendingSeek: 0) == 0)
        #expect(AetherEngine.rebuildPosition(state: .loading, clock: 0, underReconstruction: 585.9) == 585.9)
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: 10, underReconstruction: nil, pendingSeek: .nan) == 10)
    }

    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        private var dimensions: [String] = []
        private var exit: HLSSegmentProducer.PumpExitReason?
        func frame(_ buffer: CVPixelBuffer) { lock.lock(); defer { lock.unlock() }; dimensions.append("\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))") }
        func finish(_ reason: HLSSegmentProducer.PumpExitReason) { lock.lock(); defer { lock.unlock() }; exit = reason }
        var frames: [String] { lock.lock(); defer { lock.unlock() }; return dimensions }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.lock(); defer { lock.unlock() }; return exit }
    }
    private func demuxer() throws -> Demuxer {
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: Self.synthetic), formatHint: "mp4")
        return dem
    }
    @Test("Actual changing-size MP4 is decoded through both changes by the existing compatible decoder")
    func compatibleDecoder() throws {
        let dem = try demuxer(); defer { dem.close() }
        let stream = try #require(dem.stream(at: dem.videoStreamIndex))
        let result = Results(), decoder = SoftwareVideoDecoder()
        decoder.decodesSingleThreaded = true
        try decoder.open(stream: stream) { buffer, _, _ in result.frame(buffer) }
        defer { decoder.close() }
        while let pkt = try dem.readPacket() {
            if pkt.pointee.stream_index == dem.videoStreamIndex { decoder.decode(packet: pkt) }
            var owned: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&owned)
        }
        #expect(result.frames.count == 72)
        #expect(Array(result.frames.prefix(24)) == Array(repeating: "128x96", count: 24))
        #expect(Array(result.frames.dropFirst(24).prefix(24)) == Array(repeating: "192x128", count: 24))
        #expect(Array(result.frames.suffix(24)) == Array(repeating: "128x96", count: 24))
    }
    @Test("The real producer stops before writing changed-configuration video into its original init", arguments: [false, true])
    func producerStopsOnChange(coldResume: Bool) async throws {
        let dem = try demuxer(); defer { dem.close() }
        let stream = try #require(dem.stream(at: dem.videoStreamIndex))
        if coldResume { #expect(dem.seek(to: 2.0)) }
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let result = Results()
        let producer = try HLSSegmentProducer(demuxer: dem, videoStreamIndex: dem.videoStreamIndex,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base, codecTagOverride: nil),
            cache: cache, videoFallbackDurationPts: 100000, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, 4800000, 7200000])
        producer.onPumpFinished = { result.finish($0) }
        producer.start()
        defer { producer.stop(); _ = producer.waitForFinish(timeout: 2) }
        try await waitFor { result.reason != nil }
        try await waitFor { producer.waitForFinish(timeout: 0) }
        guard case .videoConfigurationChanged = result.reason else { Issue.record("expected typed config exit, got \(String(describing: result.reason))"); return }
        #expect(cache.count == 0, "a partial stale-config segment must not be cached")
    }

    @Test("A superseded pump cannot reroute a successor, and a retained early verdict is epoch-specific")
    func stalePumpVerdict() throws {
        let dem = try demuxer(); defer { dem.close() }
        let stream = try #require(dem.stream(at: dem.videoStreamIndex))
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        defer { cache.close() }
        func producer(epoch: UInt64) throws -> HLSSegmentProducer {
            try HLSSegmentProducer(demuxer: dem, videoStreamIndex: dem.videoStreamIndex,
                video: .init(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base, codecTagOverride: nil),
                cache: cache, videoFallbackDurationPts: 100000, desiredFirstVideoTfdtPts: 0,
                segmentBoundaries: [0, 7200000], epoch: epoch)
        }
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/synthetic.mp4"), dvModeAvailable: false)
        let old = try producer(epoch: 1), current = try producer(epoch: 2)
        engine.producer = current
        engine.handlePumpFinished(old, reason: .videoConfigurationChanged(summary: "synthetic change"))
        #expect(engine.pendingVODVideoConfigurationMismatch == nil)
        engine.handlePumpFinished(current, reason: .videoConfigurationChanged(summary: "synthetic change"))
        #expect(engine.pendingVODVideoConfigurationMismatch?.epoch == 2)
        engine.producer = old
        #expect(engine.pendingVODVideoConfigurationMismatch == nil)
        engine.producer = nil
        #expect(engine.pendingVODVideoConfigurationMismatch == nil)
    }

    @Test("A cold resume reaches the compatibility path and retains its paused position", .timeLimit(.minutes(3)))
    @MainActor
    func fullColdResume() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("h264-change-\(UUID().uuidString).mp4")
        try Self.synthetic.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        var events: [SoftwarePathEscalationEvent] = []
        let subscription = engine.softwarePathEscalations.sink { events.append($0) }
        defer { subscription.cancel() }
        try await engine.load(url: file, startPosition: 2.0,
            options: LoadOptions(suppressDisplayCriteria: true, autoplay: false))
        // The producer can discover the configuration change after load returns. Wait for
        // the asynchronous takeover to settle before inspecting its route, event and position.
        try await waitFor { engine.softwareHost != nil && engine.state == .paused }
        #expect(engine.loadedOptions.preferredDecodePath == .software)
        #expect(engine.softwareHost != nil)
        #expect(events.count == 1)
        #expect(events.first?.absorbedFailure.underlyingDomain == SoftwarePathEscalation.videoConfigurationErrorDomain)
        #expect(events.first?.positionSeconds == 2.0)
        #expect(engine.state == .paused)
        #expect(abs(engine.positionForSessionRebuild - 2.0) < 0.1)
    }

    // Generated solid-colour H.264, 12 fps, 128x96 -> 192x128 -> 128x96, 24 frames per run.
    // x264 main/bframes=0/repeat-headers=1/keyint=12/scenecut=0; stream-copy into MP4.
    // Contains no user media or external fixtures.
    private static let synthetic = Data(base64Encoded: "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")!
}
