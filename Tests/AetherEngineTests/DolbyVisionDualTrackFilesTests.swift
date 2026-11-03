import Testing
import Foundation
import CoreMedia
import CoreVideo
import CommonCrypto
import Darwin
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

extension HeavyDualLayerSuites {
    /// A Profile 7 FEL source whose enhancement layer is carried apart from the base layer (a Blu-ray transport
    /// stream with the layers on two PIDs, a Matroska file with two tracks) must play exactly like the same title as
    /// one remuxed track: the same frames, the same pixels, the same RPUs, over a full play and after seeks.
    ///
    /// The fixtures are generated from a single-track FEL clip, remuxed to two tracks (Matroska) or two PIDs (transport stream)
    /// and live in the directory named by `DV_FEL_DUAL_TRACK_DIR`: `single.mp4` (or `single.mkv`), `dual.mkv`,
    /// `dual.m2ts`. They are not checked in, and every test skips when they are absent.
    @Suite(.offCooperativePool)
    struct DolbyVisionDualTrackFilesTests {

        static var directory: URL? {
            ProcessInfo.processInfo.environment["DV_FEL_DUAL_TRACK_DIR"].map { URL(fileURLWithPath: $0) }
        }

        static func url(_ name: String) -> URL? { directory?.appendingPathComponent(name) }

        static func available(_ name: String) -> Bool {
            url(name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }

        static var singleName: String? { ["single.mp4", "single.mkv"].first(where: available) }

        /// The split files present, each to be compared with the single-track one.
        static var splitFiles: [String] {
            guard singleName != nil else { return [] }
            return ["dual.mkv", "dual.m2ts", "dual-noxps.mkv", "dual.mp4", "dual-ts.mp4"].filter(available)
        }

        static let needsFiles: Comment = "needs the generated dual-track files: set DV_FEL_DUAL_TRACK_DIR"

        /// Seek targets in seconds (a fixed multi-seek cycle by default), `DV_FEL_DUAL_TRACK_SEEKS` overrides.
        static var seekTargets: [Double] {
            let raw = ProcessInfo.processInfo.environment["DV_FEL_DUAL_TRACK_SEEKS"] ?? "35.144,50.144,5,20.144,35.144,50.144,5,20.144"
            return raw.split(separator: ",").compactMap { Double($0) }
        }
    }
}

private typealias DualTrackFiles = HeavyDualLayerSuites.DolbyVisionDualTrackFilesTests

/// A real-file test must never be able to take the machine down (the unpaced version of the feed below held 21 to 27 GB
/// per test helper and caused a kernel panic): the feed checks the process's footprint and stops the test past this.
private enum MemoryGuard {
    static let limitBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The highest footprint seen by a check, for the report (`DV_FEL_DUAL_TRACK_PEAK`-style output lines).
    nonisolated(unsafe) static var peak: UInt64 = 0

    struct Exceeded: Error, CustomStringConvertible {
        let bytes: UInt64
        var description: String { "memory guard: footprint \(bytes >> 20) MB passed the \(limitBytes >> 20) MB limit" }
    }

    static func check() throws {
        let now = footprint
        if now > peak { peak = now }
        if now > limitBytes { throw Exceeded(bytes: now) }
    }
}

/// One played frame: where it is in time and a digest of everything that reaches the display.
private struct PlayedFrame { var time: Double; var digest: UInt64 }

private final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [PlayedFrame] = []

    var frames: [PlayedFrame] { lock.lock(); defer { lock.unlock() }; return _frames.sorted { $0.time < $1.time } }
    func reset() { lock.lock(); _frames = []; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _frames.count }

    func take(_ buffer: CVPixelBuffer, _ time: CMTime) {
        // SHA-256 over every sample byte of every plane and the RPU attachment, truncated to 64 bits.
        var sha = CC_SHA256_CTX()
        CC_SHA256_Init(&sha)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 2 : 4)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                CC_SHA256_Update(&sha, base + y * stride, CC_LONG(rowBytes))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        if let rpu = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data {
            rpu.withUnsafeBytes { if let b = $0.baseAddress { _ = CC_SHA256_Update(&sha, b, CC_LONG(rpu.count)) } }
        } else {
            var none: UInt8 = 0xFF
            CC_SHA256_Update(&sha, &none, 1)
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &sha)
        let h = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        lock.lock(); _frames.append(PlayedFrame(time: time.seconds, digest: h)); lock.unlock()
    }
}

#if DualLayerDolbyVision
extension HeavyDualLayerSuites.DolbyVisionDualTrackFilesTests {

    private struct Play {
        let demuxer: Demuxer
        let decoder: DualLayerVideoDecoder
        let log: FrameLog
        let videoIndex: Int32
    }

    private static func open(_ name: String, join: Bool) throws -> Play {
        let demuxer = Demuxer()
        try demuxer.open(url: try #require(url(name)))
        if join { #expect(demuxer.enableDolbyVisionEnhancementLayerJoin(), "\(name) is not a joinable split source") }
        let idx = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: idx))
        let log = FrameLog()
        let decoder = DualLayerVideoDecoder(composer: DoviFelComposer())
        try decoder.open(stream: stream) { buf, pts, _ in log.take(buf, pts) }
        return Play(demuxer: demuxer, decoder: decoder, log: log, videoIndex: Int32(idx))
    }

    /// How many composed pictures may be waiting for the frame callback (which hashes ~25 MB a picture) before the
    /// feed stops reading: the decoder otherwise runs far ahead of the callback and queues gigabytes of pictures.
    private static let undeliveredLimit = 6

    /// Reads `count` video packets into the decoder, paced: after each packet it waits until at most
    /// `undeliveredLimit` pictures are undelivered, and checks the memory guard (it throws past 2 GB). A picture the
    /// decoder never outputs (leading pictures after a seek) leaves a standing gap; when nothing is delivered for a
    /// second while the feed is over the limit, the gap is taken as that and the feed goes on.
    @discardableResult
    private static func feed(_ p: Play, count: Int) async throws -> Int {
        var fed = 0, gap = 0
        let delivered0 = p.log.count
        func undelivered() -> Int { fed - (p.log.count - delivered0) - gap }
        while fed < count {
            guard let pkt = try? p.demuxer.readPacket() else { break }
            let isVideo = pkt.pointee.stream_index == p.videoIndex
            if isVideo {
                fed += 1
                p.decoder.decode(packet: pkt, epoch: nil)
            }
            av_packet_unref(pkt)
            var opt: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&opt)
            guard isVideo else { continue }
            try MemoryGuard.check()
            while undelivered() > undeliveredLimit {
                let seen = p.log.count
                let moved = try await waitFor(upTo: .seconds(1)) { undelivered() <= undeliveredLimit || p.log.count != seen }
                try MemoryGuard.check()
                if !moved { gap += undelivered() - undeliveredLimit }
            }
        }
        return fed
    }

    /// Frames of `other` against `reference` by time (within 3 ms after moving `other` by `offset`): how many pair
    /// up, and how many of those differ.
    private static func compare(_ reference: [PlayedFrame], _ other: [PlayedFrame], offset: Double)
        -> (paired: Int, differing: Int, firstDiff: Double?) {
        var paired = 0, differing = 0
        var firstDiff: Double?
        var j = 0
        for ref in reference {
            while j < other.count, other[j].time - offset < ref.time - 0.003 { j += 1 }
            guard j < other.count, abs(other[j].time - offset - ref.time) <= 0.003 else { continue }
            paired += 1
            if other[j].digest != ref.digest { differing += 1; firstDiff = firstDiff ?? ref.time }
        }
        return (paired, differing, firstDiff)
    }

    /// Every frame of a play, and how many of them are base-layer fallbacks (not composed).
    private static func fullPlay(_ name: String, join: Bool) async throws -> (frames: [PlayedFrame], fallbacks: Int) {
        let p = try open(name, join: join)
        defer { p.decoder.close(); p.demuxer.close() }
        let maxPackets = ProcessInfo.processInfo.environment["DV_FEL_DUAL_TRACK_PACKETS"].flatMap(Int.init) ?? 100_000
        try await feed(p, count: maxPackets)
        // The drain delivers the last pictures; a flush alone drops what the sessions still hold.
        p.decoder.drainForEndOfStream()
        p.decoder.quiesceForTesting()
        try MemoryGuard.check()
        #expect(p.decoder.streamClassification == .fel)
        let frames = p.log.frames
        let fallbacks = frames.count - p.decoder.composedFrameCount
        p.decoder.flush()
        return (frames, fallbacks)
    }

    @Test("a full play of the split file is bit-identical to the single-track original",
          .enabled(if: !DualTrackFiles.splitFiles.isEmpty, DualTrackFiles.needsFiles),
          arguments: DualTrackFiles.splitFiles)
    func fullPlayMatchesSingleTrack(name: String) async throws {
        MemoryGuard.peak = 0
        let singlePlay = try await Self.fullPlay(try #require(Self.singleName), join: false)
        let splitPlay = try await Self.fullPlay(name, join: true)
        let single = singlePlay.frames, split = splitPlay.frames
        #expect(single.count > 100, "the original produced \(single.count) frames")
        let offset = (split.first?.time ?? 0) - (single.first?.time ?? 0)
        let result = Self.compare(single, split, offset: offset)
        print("[dual-track] \(name): \(split.count) frames vs \(single.count), paired \(result.paired), differing \(result.differing), base-layer fallbacks \(splitPlay.fallbacks) (original \(singlePlay.fallbacks)), peak footprint \(MemoryGuard.peak >> 20) MB")
        #expect(splitPlay.fallbacks == singlePlay.fallbacks, "\(splitPlay.fallbacks) base-layer fallbacks from \(name)")
        if ProcessInfo.processInfo.environment["DV_FEL_DUAL_TRACK_PACKETS"] == nil {
            #expect(split.count == single.count, "\(split.count) frames from \(name), \(single.count) from the original")
        }
        #expect(result.paired == single.count)
        #expect(result.differing == 0, "first differing frame at \(result.firstDiff ?? -1) s")
    }

    @Test("after each seek of the default schedule the split file shows the original's frames",
          .enabled(if: !DualTrackFiles.splitFiles.isEmpty, DualTrackFiles.needsFiles),
          arguments: DualTrackFiles.splitFiles)
    func seeksMatchSingleTrack(name: String) async throws {
        let singleName = try #require(Self.singleName)
        let reference = try Self.open(singleName, join: false)
        let split = try Self.open(name, join: true)
        defer {
            reference.decoder.close(); reference.demuxer.close()
            split.decoder.close(); split.demuxer.close()
        }
        // The two start at different container times (a transport stream keeps its first PTS): align by the first frame.
        try await Self.feed(reference, count: 30); reference.decoder.drainForEndOfStream(); reference.decoder.quiesceForTesting()
        try await Self.feed(split, count: 30); split.decoder.drainForEndOfStream(); split.decoder.quiesceForTesting()
        let offset = (split.log.frames.first?.time ?? 0) - (reference.log.frames.first?.time ?? 0)
        #expect(reference.demuxer.seek(to: 0) && split.demuxer.seek(to: offset))

        for target in Self.seekTargets {
            #expect(split.demuxer.seek(to: target + offset))
            split.decoder.flush()
            split.log.reset()
            // A transport stream lands on an earlier keyframe than a file does, so it reads further to cover the same pictures.
            try await Self.feed(split, count: 200); split.decoder.drainForEndOfStream(); split.decoder.quiesceForTesting()
            // Frames that display from the target on. A transport stream may land on a later keyframe than a file
            // (the generic timestamp seek), so the comparison starts where the split source's first picture is, which
            // must still be close to the target.
            let got = split.log.frames.filter { $0.time - offset >= target }
            let landing = max(target, (got.first?.time ?? .infinity) - offset)
            // The dither's frame parity counts compositions since the flush, and the two layouts land on different
            // keyframes: the same picture can differ by the dither alone when the counts differ by an odd number.
            // So the original is played from this target once with each parity, and the split file must equal one
            // of them on every frame (the parity is then a property of the landing, not of the layout).
            var best: (want: Int, result: (paired: Int, differing: Int, firstDiff: Double?))?
            for parity in 0..<2 {
                #expect(reference.demuxer.seek(to: target))
                reference.decoder.flush()
                reference.decoder.setFrameIndexForTesting(UInt32(parity))
                reference.log.reset()
                try await Self.feed(reference, count: 100); reference.decoder.drainForEndOfStream(); reference.decoder.quiesceForTesting()
                let want = reference.log.frames.filter { $0.time >= landing - 0.003 }
                let result = Self.compare(want, got, offset: offset)
                if best == nil || result.differing < best!.result.differing { best = (want.count, result) }
            }
            let (wantCount, result) = try #require(best)
            #expect(landing - target < 5, "\(name) landed \(landing - target) s after \(target)")
            print("[dual-track] \(name) seek \(target): \(got.count) frames vs \(wantCount), paired \(result.paired), differing \(result.differing) (best of both dither parities)")
            #expect(wantCount >= 30, "the original delivered \(wantCount) frames after seeking to \(target)")
            #expect(result.paired == wantCount, "\(result.paired) of \(wantCount) frames after \(target) have a counterpart")
            #expect(result.differing == 0, "first differing frame at \(result.firstDiff ?? -1) s after seeking to \(target)")
        }
    }
}
#endif

// With or without the dual-layer trait, a split file plays as Profile 8.1 when the join is not enabled: the base
// layer's packets, each with the enhancement layer's RPU folded in, and nothing of the enhancement layer.
extension HeavyDualLayerSuites.DolbyVisionDualTrackFilesTests {

    /// Every video packet of a file (up to `DV_FEL_DUAL_TRACK_PACKETS`): its RPU (nil when it has none) and whether any
    /// enhancement NAL (unspec63) is left in it.
    private static func rpus(of name: String, fold: Bool) throws -> (rpus: [[UInt8]?], wrapped: Int) {
        MemoryGuard.peak = 0
        let demuxer = Demuxer()
        try demuxer.open(url: try #require(url(name)))
        defer { demuxer.close() }
        if fold {
            #expect(demuxer.foldsBluRayDolbyVisionLayers)
            #expect(demuxer.canJoinDolbyVisionEnhancementLayer)
            #expect(!demuxer.joinsDolbyVisionEnhancementLayer)
        }
        let idx = demuxer.videoStreamIndex
        let maxPackets = ProcessInfo.processInfo.environment["DV_FEL_DUAL_TRACK_PACKETS"].flatMap(Int.init) ?? 100_000
        let lengthPrefixed = demuxer.stream(at: idx).map { SeparateDolbyVisionLayers.framing(of: $0) != .annexB } ?? false
        let framing: VideoNALFraming = lengthPrefixed ? .lengthPrefixed(size: 4) : .annexB
        var out: [[UInt8]?] = [], wrapped = 0
        while out.count < maxPackets, let pkt = try? demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&owned) }
            guard pkt.pointee.stream_index == idx, let data = pkt.pointee.data else { continue }
            let buffer = UnsafeRawBufferPointer(start: data, count: Int(pkt.pointee.size))
            out.append(DolbyVisionLayerUnits.rpu(in: buffer, framing: framing))
            A53SEIParser.forEachNAL(data, Int(pkt.pointee.size), framing) { nal, len in
                if len > 0, (nal[0] >> 1) & 0x3F == 63 { wrapped += 1 }
            }
            if out.count % 64 == 0 { try MemoryGuard.check() }
        }
        return (out, wrapped)
    }

    @Test("without the join a split file plays as the base layer with the original's RPU folded into every picture",
          .enabled(if: !DualTrackFiles.splitFiles.isEmpty, DualTrackFiles.needsFiles),
          arguments: DualTrackFiles.splitFiles)
    func foldsWithoutTheJoin(name: String) throws {
        let single = try Self.rpus(of: try #require(Self.singleName), fold: false)
        let folded = try Self.rpus(of: name, fold: true)
        let withoutRPU = folded.rpus.filter { $0 == nil }.count
        let differing = zip(single.rpus, folded.rpus).filter { $0 != $1 }.count
        print("[dual-track] fold \(name): pictures=\(folded.rpus.count) (original \(single.rpus.count)) withoutRPU=\(withoutRPU) differingRPU=\(differing) wrapped=\(folded.wrapped), peak footprint \(MemoryGuard.peak >> 20) MB")
        #expect(folded.rpus.count > 100)
        #expect(folded.rpus.count == single.rpus.count)
        #expect(withoutRPU == 0, "\(withoutRPU) of \(folded.rpus.count) base-layer pictures have no RPU")
        #expect(differing == 0, "\(differing) pictures carry a different RPU than the original")
        #expect(folded.wrapped == 0)
    }

#if DualLayerDolbyVision
    @Test("a base layer whose record declares two-byte lengths is not joined, it keeps folding",
          .enabled(if: DualTrackFiles.available("dual.mkv"), DualTrackFiles.needsFiles))
    func twoByteLengthsAreNotJoined() throws {
        // The generated file's base-layer hvcC byte 21 (constant frame rate, layers, nesting, length size - 1) is 0x0F;
        // 0x0D declares two-byte lengths. The record is the first track's CodecPrivate: patch its first occurrence.
        var bytes = try Data(contentsOf: try #require(Self.url("dual.mkv")))
        let pattern = Data([0xF0, 0x00, 0xFC, 0xFD, 0xFA, 0xFA, 0x00, 0x00, 0x0F, 0x03])
        let at = try #require(bytes.range(of: pattern))
        bytes[at.lowerBound + 8] = 0x0D
        let patched = FileManager.default.temporaryDirectory.appendingPathComponent("dual-two-byte-\(UUID().uuidString).mkv")
        try bytes.write(to: patched)
        defer { try? FileManager.default.removeItem(at: patched) }
        let demuxer = Demuxer()
        try demuxer.open(url: patched)
        defer { demuxer.close() }
        #expect(demuxer.foldsBluRayDolbyVisionLayers)
        #expect(!demuxer.enableDolbyVisionEnhancementLayerJoin())
        #expect(!demuxer.joinsDolbyVisionEnhancementLayer)
        #expect(demuxer.foldsBluRayDolbyVisionLayers)
    }
#endif
}
