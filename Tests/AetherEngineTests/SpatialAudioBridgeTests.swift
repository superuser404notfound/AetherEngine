import Testing
import Foundation
import AVFoundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// The spatial bridge turns TrueHD Atmos into APAC for the fMP4 muxer. What it must get right
/// beyond the audio itself is time: its packets land in segments by PTS, so the first packet after
/// a load or a seek has to sit where the source says, however much the decoder skipped to find a
/// major sync, and nothing after it may drift. Packets are stamped the way AVFoundation reads APAC,
/// with the encoder's 2048 frames of priming counted in, so the first packet takes the anchor and
/// the first content frame plays there. These drive the bridge with a synthetic decoder that
/// behaves like the real one on exactly those points.
@Suite("TrueHD Atmos spatial bridge", .offCooperativePoolOneLane, .timeLimit(.minutes(5)))
struct SpatialAudioBridgeTests {
    #if TrueHDObjectAudio || DTSXObjectAudio

    /// Stand-in object decoder: one pushed byte is one 40-frame access unit (TrueHD's 1/1200 s),
    /// the first `skipAfterReset` access units after a reset are discarded as a real decoder does
    /// while it looks for a major sync, and `dropAt` discards a run mid-stream like a corrupt span.
    final class SyntheticDecoder: ObjectAudioDecoding {
        let framesPerAU = 40
        var skipAfterReset: Int
        var dropAt: (push: Int, count: Int)?
        private var pushes = 0
        private var skipped = 0
        private var inputFrames: Int64 = 0
        private var blocks: [(offset: Int64, frames: Int)] = []
        private let planes: [UnsafeMutablePointer<Float>] = (0..<3).map { _ in .allocate(capacity: 1 << 16) }
        private var t = 0

        init(skipAfterReset: Int, dropAt: (push: Int, count: Int)? = nil) {
            self.skipAfterReset = skipAfterReset
            self.dropAt = dropAt
        }
        deinit { planes.forEach { $0.deallocate() } }

        func push(_ bytes: UnsafeRawBufferPointer) throws {
            pushes += 1
            var start: Int64?
            var frames = 0
            var toDrop = (dropAt?.push == pushes) ? dropAt!.count : 0
            for _ in 0..<bytes.count {
                defer { inputFrames += Int64(framesPerAU) }
                if skipped < skipAfterReset { skipped += 1; continue }
                if toDrop > 0 {
                    toDrop -= 1
                    if frames > 0 { blocks.append((start!, frames)); start = nil; frames = 0 }
                    continue
                }
                if start == nil { start = inputFrames }
                frames += framesPerAU
            }
            if let start, frames > 0 { blocks.append((start, frames)) }
        }

        func nextBlock() throws -> ObjectAudioDecodedBlock? {
            guard !blocks.isEmpty else { return nil }
            let b = blocks.removeFirst()
            for i in 0..<b.frames {
                let v = 0.1 * sinf(Float(t + i) * 0.05)
                planes[0][i] = v; planes[1][i] = v * 0.5; planes[2][i] = v
            }
            t += b.frames
            let x = Float(t % 48_000) / 48_000
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000, frameCount: b.frames, inputFrameOffset: b.offset,
                configurationGeneration: 0, roles: [.bed(.left), .lfe, .object],
                planes: planes.map { UnsafePointer($0) },
                updates: [.init(frameOffset: 0, rampFrames: b.frames,
                                states: [.init(), .init(), .init(position: SIMD3(x, 0.5, 1))])])
        }

        func reset() { skipped = 0; inputFrames = 0; blocks = []; pushes = 0 }
    }

    /// Stand-in decoder that refuses every access unit, as a corrupt or foreign stream would.
    final class RejectingDecoder: ObjectAudioDecoding {
        struct Refused: Error {}
        func push(_ bytes: UnsafeRawBufferPointer) throws { throw Refused() }
        func nextBlock() throws -> ObjectAudioDecodedBlock? { nil }
        func reset() {}
    }

    /// Stand-in decoder with something to find: one pushed byte is one 40-frame access unit,
    /// contiguous from the first push, and the left bed channel carries a 3 ms 1 kHz burst
    /// starting at input frame `clickFrame`.
    final class ClickDecoder: ObjectAudioDecoding {
        let clickFrame: Int64
        private var inputFrames: Int64 = 0
        private var blocks: [(offset: Int64, frames: Int)] = []
        private var stateSent = false
        private let plane = UnsafeMutablePointer<Float>.allocate(capacity: 1 << 16)

        init(clickFrame: Int64) { self.clickFrame = clickFrame }
        deinit { plane.deallocate() }

        func push(_ bytes: UnsafeRawBufferPointer) throws {
            blocks.append((inputFrames, bytes.count * 40))
            inputFrames += Int64(bytes.count * 40)
        }

        func nextBlock() throws -> ObjectAudioDecodedBlock? {
            guard !blocks.isEmpty else { return nil }
            let b = blocks.removeFirst()
            for i in 0..<b.frames {
                let d = b.offset + Int64(i) - clickFrame
                plane[i] = (0..<144).contains(d) ? 0.8 * sinf(2 * .pi * 1000 * Float(d) / 48_000) : 0
            }
            defer { stateSent = true }
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000, frameCount: b.frames, inputFrameOffset: b.offset,
                configurationGeneration: 0, roles: [.bed(.left)], planes: [UnsafePointer(plane)],
                updates: stateSent ? [] : [.init(frameOffset: 0, rampFrames: 0, states: [.init()])])
        }

        func reset() { inputFrames = 0; blocks = []; stateSent = false }
    }

    /// Feed `count` 20 ms packets (24 access units) starting at `startMs` on a 1/1000 time base.
    private func feed(
        _ bridge: some AudioTranscodingBridge, startMs: Int64, count: Int
    ) throws -> [(pts: Int64, key: Bool, size: Int32)] {
        var out: [(Int64, Bool, Int32)] = []
        var payload = [UInt8](repeating: 0, count: 24)
        for i in 0..<count {
            guard let pkt = av_packet_alloc() else { continue }
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            payload.withUnsafeMutableBytes { raw in
                _ = av_new_packet(pkt, 24)
                pkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 24)
            }
            pkt.pointee.pts = startMs + Int64(i) * 20
            pkt.pointee.dts = pkt.pointee.pts
            for fp in try bridge.feed(packet: pkt) {
                out.append((fp.pointee.pts, fp.pointee.flags & AV_PKT_FLAG_KEY != 0, fp.pointee.size))
                var p: UnsafeMutablePointer<AVPacket>? = fp
                trackedPacketFree(&p)
            }
        }
        return out
    }

    #endif

    #if TrueHDObjectAudio
    @Test("only TrueHD that FFmpeg marks Atmos, at 48 kHz or not yet known, is rendered")
    func eligibility() {
        let on = ObjectAudioRendering.apac(.l714)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 48_000) == .l714)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 0) == .l714)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 0, sampleRate: 48_000) == nil,
                "TrueHD without Atmos keeps its lossless 7.1")
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 96_000) == nil)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_EAC3, profile: 30, sampleRate: 48_000) == nil,
                "E-AC-3 JOC is already Atmos and stream-copies")
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: .off, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 48_000) == nil)
    }
    #endif

    #if DTSXObjectAudio
    @Test("every 48 kHz DTS-HD MA track is a DTS:X candidate, whatever FFmpeg's label; lossy DTS is not")
    func dtsEligibility() {
        let on = ObjectAudioRendering.apac(.l714)
        // FFmpeg names only two of DTS:X's markers, so a plain DTS-HD MA label can still be DTS:X;
        // the DTS:X decoder decides on the track's first frame.
        for profile in [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX] {
            #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_DTS, profile: profile, sampleRate: 48_000) == .l714)
            #expect(HLSVideoEngine.objectAudioSource(codecID: AV_CODEC_ID_DTS, profile: profile) == .dtsHDMasterAudio)
        }
        // Only layouts that carry the 7.1 bed and the four heights one to one.
        for layout in SpatialSpeakerLayout.allCases {
            let expected: SpatialSpeakerLayout? = layout == .l714 || layout == .l916 ? layout : nil
            #expect(HLSVideoEngine.spatialRenderingLayout(
                rendering: .apac(layout), codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X,
                sampleRate: 48_000) == expected, "\(layout.rawValue)")
        }
        for profile in [AV_PROFILE_DTS, AV_PROFILE_DTS_ES, AV_PROFILE_DTS_HD_HRA, AV_PROFILE_DTS_EXPRESS] {
            #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_DTS, profile: profile, sampleRate: 48_000) == nil)
        }
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X, sampleRate: 96_000) == nil)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: .off, codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X, sampleRate: 48_000) == nil)
        #expect(HLSVideoEngine.objectAudioSource(codecID: AV_CODEC_ID_TRUEHD, profile: 30) == .trueHDAtmos)
    }
    #endif

    #if TrueHDObjectAudio || DTSXObjectAudio
    @Test("the first packet sits at the source position of the first decodable frame, and steps by 1024")
    func anchorsOnSource() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 5))
        defer { bridge.close() }
        var packets = try feed(bridge, startMs: 1000, count: 100)
        packets += bridge.flush().map { fp in
            defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
            return (fp.pointee.pts, fp.pointee.flags & AV_PKT_FLAG_KEY != 0, fp.pointee.size)
        }
        // 1000 ms = 48000 frames, plus five skipped 40-frame access units. The first packet is the
        // encoder's priming, which AVFoundation presents before its timestamp, so the first content
        // frame plays on the anchor.
        #expect(packets.first?.pts == Int64(48_200))
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == 1024 })
        #expect(packets.allSatisfy { $0.key && $0.size > 0 })
        // 96000 frames in, 200 of them skipped, after two packets of priming; the flush pads the
        // last partial packet.
        #expect(packets.count == 2 + Int((Double(96_000 - 200) / 1024).rounded(.up)))
        #expect(bridge.feedStats.packetsEmitted == packets.count)
    }

    @Test("as PCM the first packet is the first content frame on the source position, with no priming")
    func pcmAnchorsOnSourceWithoutPriming() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l916,
            decoder: SyntheticDecoder(skipAfterReset: 5), format: .lpcm)
        defer { bridge.close() }
        var packets = try feed(bridge, startMs: 1000, count: 100)
        packets += bridge.flush().map { fp in
            defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
            return (fp.pointee.pts, fp.pointee.flags & AV_PKT_FLAG_KEY != 0, fp.pointee.size)
        }
        #expect(bridge.encoderLeadingFrames == 0)
        #expect(packets.first?.pts == Int64(48_200))
        // Contiguous: each packet starts where the previous one's frames (16 channels x 3 bytes) end.
        // A chunk's last packet is shorter than 1024 frames, so the step is the length, not a constant.
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == Int64($0.size) / 48 })
        #expect(packets.allSatisfy { $0.size <= 1024 * 48 })
        // Every frame the decoder produced, 16 channels of 3 bytes each, and nothing padded.
        #expect(packets.reduce(0) { $0 + Int($1.size) } == (96_000 - 200) * 16 * 3)
        #expect(packets.allSatisfy { $0.key })
    }

    /// The APAC sample entry is written before any audio, so a decoder that never finds a major sync
    /// plays the picture over silence unless the bridge says so itself (AE#641).
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @Test("a decoder that returns or accepts nothing is reported once, at the threshold, and a healthy one never")
    func decodedNothingIsReportedOnce() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let silent = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: .max))
        defer { silent.close() }
        let reports = Reports()
        silent.onDecoderProducedNothing = { _ in reports.add() }
        let threshold = SpatialAudioBridge.silentFeedPacketThreshold
        _ = try feed(silent, startMs: 0, count: threshold - 1)
        #expect(reports.value == 0)
        _ = try feed(silent, startMs: Int64(threshold - 1) * 20, count: 40)
        #expect(reports.value == 1)

        let rejecting = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: RejectingDecoder())
        defer { rejecting.close() }
        let rejected = Reports()
        rejecting.onDecoderProducedNothing = { _ in rejected.add() }
        _ = try feed(rejecting, startMs: 0, count: SpatialAudioBridge.silentFeedPacketThreshold + 10)
        #expect(rejected.value == 1)

        let healthy = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 5))
        defer { healthy.close() }
        let quiet = Reports()
        healthy.onDecoderProducedNothing = { _ in quiet.add() }
        _ = try feed(healthy, startMs: 0, count: 100)
        #expect(quiet.value == 0)
    }

    /// The resume that put a tvOS session into `.error`: TrueHD in Matroska or M2TS is one 40-frame
    /// access unit per packet, and after a mid-stream start the decoder skips to the next major sync,
    /// 102 access units on Dolby's Unfold demo. That wait is not a dead decoder.
    @Test("a mid-stream start that waits 102 access units for a major sync is not reported as silence")
    func majorSyncWaitIsNotSilence() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 48_000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 102))
        defer { bridge.close() }
        let reports = Reports()
        bridge.onDecoderProducedNothing = { _ in reports.add() }
        var emitted = 0
        for i in 0..<300 {
            guard let pkt = av_packet_alloc() else { continue }
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            _ = av_new_packet(pkt, 1)
            pkt.pointee.pts = Int64(i) * 40
            pkt.pointee.dts = pkt.pointee.pts
            for fp in try bridge.feed(packet: pkt) {
                emitted += 1
                var p: UnsafeMutablePointer<AVPacket>? = fp
                trackedPacketFree(&p)
            }
        }
        #expect(reports.value == 0)
        #expect(emitted > 0, "the decoder found its sync and the bridge encoded")
    }

    /// The encoder runs on its own queue, so a feed returns what earlier chunks encoded. Settled
    /// before every cut, the split is the one a synchronous encode makes.
    @Test("settled after every feed, the bridge returns a synchronous encode's packets at each point")
    func settleRestoresTheSynchronousSplit() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let pipelined = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: ClickDecoder(clickFrame: 30_000))
        let settledEachFeed = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: ClickDecoder(clickFrame: 30_000))
        defer { pipelined.close(); settledEachFeed.close() }
        func take(_ packets: [UnsafeMutablePointer<AVPacket>]) -> [(pts: Int64, data: Data)] {
            packets.map { fp in
                defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
                return (fp.pointee.pts, Data(bytes: fp.pointee.data, count: Int(fp.pointee.size)))
            }
        }
        func feedOne(_ bridge: SpatialAudioBridge, ms: Int64) throws -> [(pts: Int64, data: Data)] {
            let pkt = av_packet_alloc()!
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            _ = av_new_packet(pkt, 24)
            pkt.pointee.pts = ms
            pkt.pointee.dts = ms
            return take(try bridge.feed(packet: pkt))
        }
        var a: [(pts: Int64, data: Data)] = [], b: [(pts: Int64, data: Data)] = []
        for round in 0..<4 {
            for i in 0..<25 {
                let ms = Int64(round * 25 + i) * 20
                a += try feedOne(pipelined, ms: ms)
                b += try feedOne(settledEachFeed, ms: ms) + take(settledEachFeed.settle())
            }
            a += take(pipelined.settle())
            #expect(a.map(\.pts) == b.map(\.pts), "after a cut both hold the same packets")
        }
        a += take(pipelined.flush())
        b += take(settledEachFeed.flush())
        #expect(!a.isEmpty)
        #expect(a.map(\.pts) == b.map(\.pts))
        #expect(a.map(\.data) == b.map(\.data))
    }

    /// Like `ClickDecoder`, but returns nothing after a reset until the bridge asks for what it
    /// holds, as the TrueHD decoder does while it waits for the first object metadata.
    final class HoldingDecoder: ObjectAudioDecoding {
        private let inner = ClickDecoder(clickFrame: 30_000)
        private var holding = true
        private(set) var releases = 0

        func push(_ bytes: UnsafeRawBufferPointer) throws { try inner.push(bytes) }
        func nextBlock() throws -> ObjectAudioDecodedBlock? { holding ? nil : try inner.nextBlock() }
        func reset() { inner.reset(); holding = true }
        func releaseHeldBlocks() { releases += 1; holding = false }
    }

    /// A cut settles the bridge, and what the decoder holds plays before that cut, so the hold moves
    /// no audio into the next segment.
    @Test("a cut releases what the decoder holds, so it splits as a decoder without a hold does")
    func settleReleasesHeldBlocks() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let holding = HoldingDecoder()
        let held = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: holding)
        let plain = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: ClickDecoder(clickFrame: 30_000))
        defer { held.close(); plain.close() }
        func take(_ packets: [UnsafeMutablePointer<AVPacket>]) -> [(pts: Int64, data: Data)] {
            packets.map { fp in
                defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
                return (fp.pointee.pts, Data(bytes: fp.pointee.data, count: Int(fp.pointee.size)))
            }
        }
        var a = try feed(held, startMs: 0, count: 25).map(\.pts)
        var b = try feed(plain, startMs: 0, count: 25).map(\.pts)
        a += take(held.settle()).map(\.pts)
        b += take(plain.settle()).map(\.pts)
        #expect(!b.isEmpty)
        #expect(a == b, "after the cut both carry the same packets")
        #expect(holding.releases == 1)
        a += try feed(held, startMs: 500, count: 25).map(\.pts) + take(held.flush()).map(\.pts)
        b += try feed(plain, startMs: 500, count: 25).map(\.pts) + take(plain.flush()).map(\.pts)
        #expect(a == b)
    }

    @Test("a producer restart re-anchors on the new position")
    func restartReanchors() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l916,
            decoder: SyntheticDecoder(skipAfterReset: 3))
        defer { bridge.close() }
        _ = try feed(bridge, startMs: 0, count: 30)
        bridge.startSegment()
        let packets = try feed(bridge, startMs: 5000, count: 30)
        #expect(packets.first?.pts == Int64(240_120))
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == 1024 })
    }

    @Test("a span the decoder drops is filled, so everything after it keeps its timestamp")
    func gapKeepsTimeline() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 0, dropAt: (push: 10, count: 12)))
        defer { bridge.close() }
        var packets = try feed(bridge, startMs: 0, count: 100)
        packets += bridge.flush().map { fp in
            defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
            return (fp.pointee.pts, true, fp.pointee.size)
        }
        #expect(packets.first?.pts == Int64(0))
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == 1024 })
        // 100 packets x 960 frames in, the dropped 480 included as silence: the tail, presented
        // 2048 frames before its timestamp, reaches the end.
        let end = packets.last!.pts + 1024 - 2048
        #expect(end >= 96_000 && end < 96_000 + 1024)
    }

    /// Mux `count` 20 ms source packets from `startMs` through the bridge, next to the probe video
    /// movenc needs, and cut one segment. Returns the init segment, the segment file and the
    /// session directory it sits in (the caller removes it).
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func muxWithProbeVideo(
        _ bridge: SpatialAudioBridge, startMs: Int64, count: Int
    ) throws -> (initBytes: Data, segment: URL, sessionDir: URL)? {
        let videoDemuxer = Demuxer()
        defer { videoDemuxer.close() }
        try videoDemuxer.open(
            reader: DataIOReader(data: Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                            options: .ignoreUnknownCharacters)!),
            formatHint: "mp4")
        let vStream = try #require(videoDemuxer.stream(at: videoDemuxer.videoStreamIndex))
        let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        var initBytes: Data?
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0, sessionDir: sessionDir,
            video: .init(codecpar: UnsafePointer(vStream.pointee.codecpar), timeBase: vStream.pointee.time_base,
                         codecTagOverride: nil),
            audio: .init(codecpar: UnsafePointer(bridge.encoderCodecpar!), timeBase: bridge.encoderTimeBase,
                         soundSampleEntryOverride: bridge.soundSampleEntryOverride),
            onInitCaptured: { initBytes = $0 })

        while let pkt = try videoDemuxer.readPacket() {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&p) }
            guard pkt.pointee.stream_index == videoDemuxer.videoStreamIndex else { continue }
            pkt.pointee.stream_index = muxer.videoOutputStreamIndex
            av_packet_rescale_ts(pkt, vStream.pointee.time_base, muxer.muxerVideoTimeBase)
            _ = muxer.writePacket(pkt)
        }
        var payload = [UInt8](repeating: 0, count: 24)
        for i in 0..<count {
            let pkt = av_packet_alloc()!
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            payload.withUnsafeMutableBytes { raw in
                _ = av_new_packet(pkt, 24)
                pkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 24)
            }
            pkt.pointee.pts = startMs + Int64(i) * 20
            for fp in try bridge.feed(packet: pkt) + (i == count - 1 ? bridge.flush() : []) {
                var p: UnsafeMutablePointer<AVPacket>? = fp
                defer { trackedPacketFree(&p) }
                fp.pointee.stream_index = muxer.audioOutputStreamIndex
                av_packet_rescale_ts(fp, bridge.encoderTimeBase, muxer.muxerAudioTimeBase)
                #expect(muxer.writePacket(fp).rc >= 0)
            }
        }
        guard case .completed(let segment, _) = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("the stand-in needs no parsed packet, so the cut completes")
            return nil
        }
        return (try #require(initBytes), segment, sessionDir)
    }

    #endif
    @Test("the Atmos output activator's bundled stream reads as E-AC-3 with the Atmos extension")
    @MainActor
    func silentAtmosStreamIsAtmos() async throws {
        let asset = AVURLAsset(url: AtmosOutputActivator.silentAtmosStream)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        // AVFoundation lists an E-AC-3 track whose dec3 box states the Atmos extension as 'ec+3'
        // layers (objects first) over its 'ec-3' core.
        var size = 0
        let list = try #require(CMAudioFormatDescriptionGetFormatList(format, sizeOut: &size))
        #expect(size >= MemoryLayout<AudioFormatListItem>.size)
        #expect(list[0].mASBD.mFormatID == 0x6563_2B33)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatEnhancedAC3)
    }

    #if TrueHDObjectAudio || DTSXObjectAudio
    @Test("movenc muxes the stand-in and the init segment carries the real apac entry")
    func muxedInitCarriesAPAC() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 0))
        defer { bridge.close() }
        guard let muxed = try muxWithProbeVideo(bridge, startMs: 0, count: 50) else { return }
        let sessionDir = muxed.sessionDir
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        let bytes = muxed.initBytes
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        #expect(hex.contains("61706163"), "apac sample entry present")
        #expect(hex.contains("64617061"), "dapa configuration present")
        #expect(!hex.contains("616c6163"), "no alac left behind")
        #expect(bytes.range(of: bridge.soundSampleEntryOverride!) != nil)

        if let dump = ProcessInfo.processInfo.environment["AE_SPATIAL_DUMP_DIR"] {
            let dir = URL(fileURLWithPath: dump)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: dir.appendingPathComponent("init.mp4"))
            let seg = try FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)
            for file in seg { try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent)) }
        }
    }

    @Test("movenc muxes the PCM bed as ipcm with its channel layout and no stand-in")
    func muxedInitCarriesPCM() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l916,
            decoder: SyntheticDecoder(skipAfterReset: 0), format: .lpcm)
        defer { bridge.close() }
        #expect(bridge.soundSampleEntryOverride == nil)
        #expect(bridge.hlsCodecs == "ipcm")
        #expect(bridge.servedChannelCount == 16)
        guard let muxed = try muxWithProbeVideo(bridge, startMs: 0, count: 50) else { return }
        defer { try? FileManager.default.removeItem(at: muxed.sessionDir) }
        let hex = muxed.initBytes.map { String(format: "%02x", $0) }.joined()
        #expect(hex.contains("6970636d"), "ipcm sample entry present")
        #expect(hex.contains("63686e6c"), "chnl box present")
        #expect(!hex.contains("61706163") && !hex.contains("616c6163"), "no apac, no alac stand-in")
    }

    /// The end-to-end form of the timestamp contract: a click at a known source position is
    /// rendered, encoded, muxed and decoded back by AVFoundation, which presents APAC the way
    /// AVPlayer does, and has to come out where the source put it. With the encoder's priming
    /// packets dropped it came out 2048 frames (42.7 ms) early, and so did every session's audio.
    @Test("a click decodes back at its source position through AVFoundation, as APAC and as PCM",
          arguments: [SpatialBedFormat.apac, .lpcm])
    func clickDecodesOnItsSourcePosition(format: SpatialBedFormat) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // The source starts at 0 and the click is 12000 frames in, so it belongs at 0.25 s.
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: ClickDecoder(clickFrame: 12_000), format: format)
        defer { bridge.close() }
        guard let muxed = try muxWithProbeVideo(bridge, startMs: 0, count: 30) else { return }
        let sessionDir = muxed.sessionDir
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        let file = sessionDir.appendingPathComponent("joined.mp4")
        try (muxed.initBytes + Data(contentsOf: muxed.segment)).write(to: file)

        let asset = AVURLAsset(url: file)
        nonisolated(unsafe) let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        // copyNextSampleBuffer blocks until AVFoundation has decoded the next buffer. Called from the
        // cooperative pool it held one of a three-core CI runner's threads while that decode waited
        // for one, and the whole test process stalled. A thread of its own cannot starve the pool.
        let decoded = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Double?, Error>, Never>) in
            Thread.detachNewThread {
                continuation.resume(returning: Result { try Self.clickOnset(asset: asset, track: track) })
            }
        }
        let heard = try #require(try decoded.get(), "the click reaches the left channel")
        #expect(abs(heard - 0.25) < 0.001, "the click decodes at \(heard) s, not at its source position 0.25 s")
    }

    /// Decodes the track to PCM and returns when the left channel first rises above the click
    /// threshold, or nil when it never does. Blocks until AVFoundation has decoded that far.
    private static func clickOnset(asset: AVURLAsset, track: AVAssetTrack) throws -> Double? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        while let buffer = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = Int(asbd.mChannelsPerFrame)
            let frames = CMSampleBufferGetNumSamples(buffer)
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            var block: CMBlockBuffer?
            var list = AudioBufferList()
            _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
            guard let samples = list.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if let i = (0..<frames).first(where: { abs(samples[$0 * channels]) > 0.2 }) {
                return start + Double(i) / 48_000
            }
        }
        return nil
    }
    #endif
}

#if TrueHDObjectAudio || DTSXObjectAudio
/// The bed level line is the engine's half of a missing-heights report: it says which channels of the
/// rendered bed carried sound in what AVPlayer was handed, so a silent height here and a silent height
/// at the receiver are told apart.
@Suite("TrueHD Atmos bed level meter")
struct BedLevelMeterTests {

    /// `chunks` encode chunks (2048 frames, as the bridge feeds it) of a half-scale sine on one channel
    /// of a 7.1.4 bed, the rest silent. At 48 kHz the 5 s first window closes on chunk 118 and a 30 s
    /// window on chunk 704.
    private func feed(_ meter: inout BedLevelMeter, chunks: Int, channel: Int = 0,
                      startSeconds: Double? = nil) -> [String] {
        let layout = SpatialSpeakerLayout.l714
        let chunk = 2048
        let planes = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
        defer { planes.forEach { $0.deallocate() } }
        for c in planes.indices { planes[c].update(repeating: 0, count: chunk) }
        for i in 0..<chunk { planes[channel][i] = 0.5 * sinf(2 * .pi * Float(i) / 64) }
        var lines: [String] = []
        for i in 0..<chunks {
            let at = startSeconds.map { $0 + Double(i * chunk) / 48_000 }
            if let line = meter.add(planes.map { UnsafePointer($0) }, frameCount: chunk, startSeconds: at) {
                lines.append(line)
            }
        }
        return lines
    }

    @Test("the first window closes after 5 s, later ones every 30 s, and a seek starts a short one again")
    func windows() {
        var meter = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        #expect(feed(&meter, chunks: 117).isEmpty)
        #expect(feed(&meter, chunks: 1).count == 1)
        #expect(feed(&meter, chunks: 703).isEmpty)
        #expect(feed(&meter, chunks: 1).count == 1)
        // Under a second is not worth a line; two seconds is, and the next window is a first one.
        _ = feed(&meter, chunks: 23)
        #expect(meter.restart() == nil)
        _ = feed(&meter, chunks: 47)
        #expect(meter.restart()?.contains("over 2.0 s") == true)
        #expect(feed(&meter, chunks: 118).count == 1)
    }

    @Test("each channel carries its CoreAudio name in layout order with RMS and peak, a silent one -inf")
    func levels() throws {
        var meter = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        let line = try #require(feed(&meter, chunks: 118, channel: 9, startSeconds: 3725.4).first)
        // A half-scale sine: RMS 0.354 is -9.0 dBFS, peak 0.5 is -6.0. The names are the ones
        // CoreAudioBaseTypes.h gives kAudioChannelLayoutTag_Atmos_7_1_4, as on the route line.
        #expect(line.hasPrefix("bed levels 7.1.4 at 3725.4 s over 5.0 s, rms/peak dBFS: L -inf/-inf, "
                               + "R -inf/-inf, C -inf/-inf, LFE -inf/-inf, Ls -inf/-inf, Rs -inf/-inf, "
                               + "Rls -inf/-inf, Rrs -inf/-inf, Vhl -inf/-inf, Vhr -9.0/-6.0, Ltr -inf/-inf, "
                               + "Rtr -inf/-inf;"))
    }

    @Test("objects count as active with gain and as elevated only above ear level with elevation allowed")
    func objectCounts() throws {
        var meter = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        let roles: [ObjectAudioRole] = [.lfe, .object, .object, .object]
        let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
        let first = ObjectAudioMetadataUpdate(frameOffset: 0, rampFrames: 0, states: [
            .init(),
            .init(position: SIMD3(0.5, 0.5, 1)),                       // overhead
            .init(position: SIMD3(0.5, 0.5, 1), excluded: heights),     // elevation not allowed
            .init(position: SIMD3(0.5, 0.5, 1), gain: 0),               // muted
        ])
        // A later update restates only the muted object; the others keep their last state.
        let second = ObjectAudioMetadataUpdate(frameOffset: 0, rampFrames: 0, states: [
            nil, nil, nil, .init(position: SIMD3(0, 0, 0)),
        ])
        meter.observe(roles: roles, updates: [first, second])
        let line = try #require(feed(&meter, chunks: 118).first)
        #expect(line.contains("; objects: up to 3 active, 1 elevated;"))
        // Metadata that holds still sends no update; the next window still reports what plays.
        let held = try #require(feed(&meter, chunks: 704).first)
        #expect(held.contains("; objects: up to 3 active, 1 elevated;"))
        // A seek forgets the objects until the decoder restates them.
        _ = meter.restart()
        let afterSeek = try #require(feed(&meter, chunks: 118).first)
        #expect(afterSeek.contains("; objects: up to 0 active, 0 elevated;"))
    }

    @Test("the counts reach LiveTelemetry as they stand, with heights carried as bed channels")
    func activityForTelemetry() {
        var meter = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        #expect(meter.activity == ObjectAudioActivity(
            layout: .l714, objects: 0, activeObjects: 0, elevatedObjects: 0, heightChannels: 0))
        // DTS:X's standard presentation: its heights are bed channels, not objects.
        meter.observe(roles: [.bed(.left), .bed(.right), .bed(.topFrontLeft), .bed(.topFrontRight)], updates: [])
        #expect(meter.activity == ObjectAudioActivity(
            layout: .l714, objects: 0, activeObjects: 0, elevatedObjects: 0, heightChannels: 2))
        // TrueHD Atmos: an LFE and objects, one overhead, one at ear level, one muted.
        meter.observe(roles: [.lfe, .object, .object, .object], updates: [ObjectAudioMetadataUpdate(
            frameOffset: 0, rampFrames: 0, states: [
                .init(), .init(position: SIMD3(0.5, 0.5, 1)), .init(position: SIMD3(0.5, 0.5, 0)), .init(gain: 0),
            ])], configurationChanged: true)
        #expect(meter.activity == ObjectAudioActivity(
            layout: .l714, objects: 3, activeObjects: 2, elevatedObjects: 1, heightChannels: 0))
        // A seek forgets which objects play until the decoder restates them; the configuration stays.
        _ = meter.restart()
        #expect(meter.activity.activeObjects == 0)
        #expect(meter.activity.objects == 3)
    }

    @Test("a configuration without objects does not keep reporting the previous configuration's objects")
    func countsResetOnConfigurationChange() throws {
        var meter = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        meter.observe(roles: [.object], updates: [ObjectAudioMetadataUpdate(
            frameOffset: 0, rampFrames: 0, states: [.init(position: SIMD3(0.5, 0.5, 1))])])
        let first = try #require(feed(&meter, chunks: 118).first)
        #expect(first.contains("; objects: up to 1 active, 1 elevated;"))
        meter.observe(roles: [.bed(.left)], updates: [], configurationChanged: true)
        // The window open at the change saw the object play; the one after it must not.
        let during = try #require(feed(&meter, chunks: 704).first)
        #expect(during.contains("; objects: up to 1 active, 1 elevated;"))
        let after = try #require(feed(&meter, chunks: 704).first)
        #expect(after.contains("; objects: up to 0 active, 0 elevated;"))
    }

    @Test("the line ends with the LFE element's input level and metadata gain, or says there is none")
    func lfeInputAndGain() throws {
        var meter = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        let roles: [ObjectAudioRole] = [.lfe, .object]
        meter.observe(roles: roles, updates: [ObjectAudioMetadataUpdate(
            frameOffset: 0, rampFrames: 0, states: [.init(gain: 0.5), .init(position: SIMD3(0.5, 0.5, 0))])])
        let frames = 48_000
        let lfe = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let object = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { lfe.deallocate(); object.deallocate() }
        for i in 0..<frames { lfe[i] = 0.5 * sinf(2 * .pi * Float(i) / 64); object[i] = 0 }
        meter.measureInput(roles: roles, planes: [UnsafePointer(lfe), UnsafePointer(object)], frameCount: frames)
        let line = try #require(feed(&meter, chunks: 118).first)
        #expect(line.hasSuffix("; LFE input -9.0 dBFS, metadata gain -6.0 dB"))

        // TrueHD can carry LFE2 beside LFE; the renderer sums both, so the meter does too, and names
        // each element's gain.
        var twoLFE = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        let twoRoles: [ObjectAudioRole] = [.lfe, .lfe]
        twoLFE.observe(roles: twoRoles, updates: [ObjectAudioMetadataUpdate(
            frameOffset: 0, rampFrames: 0, states: [.init(), .init(gain: 0.5)])])
        twoLFE.measureInput(roles: twoRoles, planes: [UnsafePointer(object), UnsafePointer(lfe)], frameCount: frames)
        let both = try #require(feed(&twoLFE, chunks: 118).first)
        #expect(both.hasSuffix("; LFE input -9.0 dBFS, metadata gain 0.0 dB/-6.0 dB"))

        var noLFE = BedLevelMeter(layout: .l714, sampleRate: 48_000)
        noLFE.observe(roles: [.object], updates: [])
        let without = try #require(feed(&noLFE, chunks: 118).first)
        #expect(without.hasSuffix("; no LFE element"))
        #expect(BedLevelMeter.configurationSummary([.lfe] + Array(repeating: .object, count: 15)) == "LFE + 15 objects")
        #expect(BedLevelMeter.configurationSummary([.bed(.left), .bed(.right), .object]) == "beds L R + no LFE + 1 objects")
    }
}

extension SpatialAudioBridgeTests {
    // MARK: - Review round 1 of the bridge (#731)

    /// Contiguous like `ClickDecoder`, but at push `panicAt` it fails the way the real one does on a
    /// caught panic: the push throws, the decoder resets itself, and its offsets start from zero.
    final class SelfResettingDecoder: ObjectAudioDecoding {
        let panicAt: Int
        private var pushes = 0
        private var inputFrames: Int64 = 0
        private var blocks: [(offset: Int64, frames: Int)] = []
        private let plane = UnsafeMutablePointer<Float>.allocate(capacity: 1 << 16)
        private(set) var selfResetCount = 0
        struct Panic: Error {}

        init(panicAt: Int) { self.panicAt = panicAt; plane.initialize(repeating: 0.1, count: 1 << 16) }
        deinit { plane.deallocate() }

        func push(_ bytes: UnsafeRawBufferPointer) throws {
            pushes += 1
            if pushes == panicAt {
                inputFrames = 0; blocks = []; selfResetCount += 1
                throw Panic()
            }
            blocks.append((inputFrames, bytes.count * 40))
            inputFrames += Int64(bytes.count * 40)
        }

        func nextBlock() throws -> ObjectAudioDecodedBlock? {
            guard !blocks.isEmpty else { return nil }
            let b = blocks.removeFirst()
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000, frameCount: b.frames, inputFrameOffset: b.offset,
                configurationGeneration: 0, roles: [.bed(.left)], planes: [UnsafePointer(plane)], updates: [])
        }

        func reset() { inputFrames = 0; blocks = [] }
    }

    /// Decodes fine at a rate the renderer refuses, so every block throws.
    final class WrongRateDecoder: ObjectAudioDecoding {
        private var pending = 0
        private let plane = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        deinit { plane.deallocate() }
        func push(_ bytes: UnsafeRawBufferPointer) throws { pending += 1 }
        func nextBlock() throws -> ObjectAudioDecodedBlock? {
            guard pending > 0 else { return nil }
            pending -= 1
            return ObjectAudioDecodedBlock(
                sampleRate: 44_100, frameCount: 40, inputFrameOffset: 0, configurationGeneration: 0,
                roles: [.bed(.left)], planes: [UnsafePointer(plane)], updates: [])
        }
        func reset() { pending = 0 }
    }

    private func drain(_ bridge: some AudioTranscodingBridge) -> [Int64] {
        bridge.flush().map { fp in
            defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
            return fp.pointee.pts
        }
    }

    @Test("after the decoder resets itself mid-stream, later audio keeps its source position")
    func selfResetReanchors() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: SelfResettingDecoder(panicAt: 50))
        defer { bridge.close() }
        // 100 packets of 20 ms from 1 s. Packet 50 is lost to the panic; its 960 frames come back as
        // silence, so the stream is as long as an unbroken one. Appended onto the encoder instead,
        // everything after the panic would play 20 ms early and the stream would end a packet short.
        let packets = try feed(bridge, startMs: 1000, count: 100).map(\.pts) + drain(bridge)
        #expect(packets.first == 48_000)
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1 - $0 == 1024 })
        #expect(packets.count == 2 + Int((Double(96_000) / 1024).rounded(.up)))
    }

    @Test("a seek after the end of the file anchors on the new position")
    func seekAfterEOF() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: ClickDecoder(clickFrame: .max))
        defer { bridge.close() }
        _ = try feed(bridge, startMs: 0, count: 50)
        _ = drain(bridge)
        bridge.startSegment()
        let after = try feed(bridge, startMs: 5000, count: 50)
        #expect(after.first?.pts == 240_000, "5 s at 48 kHz")
        #expect(!after.isEmpty)
    }

    @Test("a bridge whose every feed fails is reported once and never throws at the producer")
    func persistentFailureReportedOnce() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: WrongRateDecoder())
        defer { bridge.close() }
        let reports = Reports()
        bridge.onDecoderProducedNothing = { _ in reports.add() }
        let out = try feed(bridge, startMs: 0, count: SpatialAudioBridge.silentFeedPacketThreshold * 2 + 5)
        #expect(out.isEmpty)
        #expect(reports.value == 1)
    }

    @Test("the master's CHANNELS counts the bed, not the 2-channel stand-in the muxer is given",
          arguments: [SpatialSpeakerLayout.l714, .l916])
    func servedChannelsAreTheBeds(layout: SpatialSpeakerLayout) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: layout, decoder: ClickDecoder(clickFrame: .max))
        defer { bridge.close() }
        #expect(bridge.encoderCodecpar?.pointee.ch_layout.nb_channels == 2)
        #expect(bridge.servedChannelCount == layout.channelCount)
    }

    /// Feed the software host's APAC producer the way `feed` feeds the bridge, with the epoch the demux
    /// thread read before the read, and return the buffers' presentation times in seconds.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func feedProducer(
        _ producer: SoftwareAPACProducer, startMs: Int64, count: Int, epoch: UInt64
    ) -> [Double] {
        var out: [Double] = []
        var payload = [UInt8](repeating: 0, count: 24)
        for i in 0..<count {
            guard let pkt = av_packet_alloc() else { continue }
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            payload.withUnsafeMutableBytes { raw in
                _ = av_new_packet(pkt, 24)
                pkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 24)
            }
            pkt.pointee.pts = startMs + Int64(i) * 20
            pkt.pointee.dts = pkt.pointee.pts
            out += producer.decode(packet: pkt, epoch: epoch).map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        }
        return out
    }

    /// PR #808 review, item 3: the demux loop checks the seek generation and then feeds. A seek whose
    /// flush (`startSegment`) lands between the two used to let the pre-seek packet become the new
    /// run's anchor, and the bridge stamps the whole run from it: here the audio after the seek to 60 s
    /// would have been stamped from 1 s, 59 s in the past, and dropped as late until the next seek.
    @Test("a packet read before a seek's flush cannot anchor the run after it")
    func stalePacketDoesNotAnchorThePostSeekRun() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714, decoder: ClickDecoder(clickFrame: .max))
        let stream = UnsafeMutablePointer<AVStream>.allocate(capacity: 1)
        stream.initialize(to: AVStream())
        defer { stream.deallocate() }
        let producer = SoftwareAPACProducer(bridge: bridge, stream: stream)
        defer { producer.close() }

        _ = feedProducer(producer, startMs: 0, count: 50, epoch: producer.feedEpoch)
        // The demux thread reads the epoch and a packet at 1 s; the seek's flush lands before the feed.
        let staleEpoch = producer.feedEpoch
        producer.flush()
        #expect(feedProducer(producer, startMs: 1000, count: 1, epoch: staleEpoch).isEmpty)

        // The post-seek run anchors on its own first packet, at 60 s: the first buffer is the encoder's
        // priming, presented `encoderLeadingFrames` before the anchor so the first content frame plays on it.
        let after = feedProducer(producer, startMs: 60_000, count: 50, epoch: producer.feedEpoch)
        let first = try #require(after.first)
        let expected = 60.0 - Double(bridge.encoderLeadingFrames) / Double(SpatialAudioBridge.sampleRate)
        #expect(abs(first - expected) < 0.001, "first buffer at \(first) s, expected \(expected) s")
    }
}
#endif
