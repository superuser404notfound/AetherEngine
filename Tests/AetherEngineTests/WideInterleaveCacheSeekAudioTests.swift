import Foundation
import Testing
@testable import AetherEngine

/// AE#1093: a cached seek restored the FIFO to the video keyframe's record only. With audio muxed in
/// long blocks (here 10 s of audio ahead of two 5 s GOPs, the DASH `SegmentBase` shape) the audio for
/// that keyframe sits BEFORE its record, so the hit skipped it and played silent until the next audio
/// block: a seek to 15 s delivered its first audio at 20 s. Fixture shape from the report (nulltuple).
@Suite("Wide-interleave software cache seek", .offCooperativePool, .timeLimit(.minutes(3)))
struct WideInterleaveCacheSeekAudioTests {
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private let packets: [SoftwareStoredPacket]
        private var nextIndex = 0

        init(_ packets: [SoftwareStoredPacket]) { self.packets = packets }

        func next() -> SoftwareStoredPacket? {
            lock.lock()
            defer { lock.unlock() }
            guard nextIndex < packets.count else { return nil }
            defer { nextIndex += 1 }
            return packets[nextIndex]
        }
    }

    enum Store: Sendable { case disk, memory }

    private static func packet(_ pts: Int64, stream: Int32, key: Bool) -> SoftwareStoredPacket {
        SoftwareStoredPacket(
            pts: pts, dts: pts, duration: 100, position: 0,
            streamIndex: stream, flags: key ? 1 : 0,
            timeBaseNumerator: 1, timeBaseDenominator: 1000,
            bytes: Data(repeating: stream == 1 ? 0xAA : 0xBB, count: 64),
            sideData: []
        )
    }

    /// Audio [0,10) then video [0,5) [5,10), audio [10,20) then video [10,15) [15,20), audio [20,30)
    /// then video [20,25). 100 ms packets, one keyframe per 5 s GOP.
    private static func wideInterleave(audioKey: Bool = true) -> [SoftwareStoredPacket] {
        var packets: [SoftwareStoredPacket] = []
        for segment in 0..<3 {
            let base = Int64(segment) * 10_000
            for offset in stride(from: Int64(0), to: 10_000, by: 100) {
                packets.append(packet(base + offset, stream: 1, key: audioKey))
            }
            for half in 0..<2 {
                let videoBase = base + Int64(half) * 5_000
                if videoBase >= 25_000 { continue }
                for offset in stride(from: Int64(0), to: 5_000, by: 100) {
                    packets.append(packet(videoBase + offset, stream: 0, key: offset == 0))
                }
            }
        }
        return packets
    }

    /// The usual muxer shape: each 100 ms of video followed by its 100 ms of audio.
    private static func fineInterleave() -> [SoftwareStoredPacket] {
        var packets: [SoftwareStoredPacket] = []
        for pts in stride(from: Int64(0), to: 25_000, by: 100) {
            packets.append(packet(pts, stream: 0, key: pts % 5_000 == 0))
            packets.append(packet(pts, stream: 1, key: true))
        }
        return packets
    }

    private func cachedSource(_ packets: [SoftwareStoredPacket], store: Store = .disk,
                              anchorsOnLastKeyframe: Bool) throws -> (SoftwarePacketReadAhead, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wide-interleave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fifo: any SoftwarePacketStore = switch store {
        case .disk: try SoftwarePacketDiskFIFO(chunkTargetBytes: 16_384, parentDirectory: root)
        case .memory: SoftwarePacketMemoryFIFO(chunkTargetBytes: 16_384, historyCapBytes: 4_000_000,
                                               kernelMayPurge: false)
        }
        let feed = Feed(packets)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: .init(index: 1, numerator: 1, denominator: 1000),
            byteBudget: 4_000_000,
            forwardSeconds: 3600,
            initialSourceClock: 0,
            fifo: fifo,
            anchorsOnLastKeyframe: anchorsOnLastKeyframe
        ) { _ in feed.next() }
        source.start()
        let deadline = Date().addingTimeInterval(10)
        while !source.snapshot.sourceEnded && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(source.snapshot.sourceEnded, "fixture was not fully cached")
        return (source, root)
    }

    private struct Landing {
        var hit: Bool
        var firstAudio: Int64?
        var firstVideo: Int64?
        var firstPacket: SoftwareStoredPacket?
    }

    /// Seeks, then reads until both streams have shown their first packet.
    private func seek(_ source: SoftwarePacketReadAhead, to seconds: Double) throws -> Landing {
        let token = source.beginSeek(to: seconds)
        let hit = try source.prepareSeek(token, to: seconds)
        source.endSeek(token, sourceClock: seconds)
        var landing = Landing(hit: hit)
        guard hit else { return landing }
        while landing.firstAudio == nil || landing.firstVideo == nil {
            guard let next = try source.read() else { break }
            if landing.firstPacket == nil { landing.firstPacket = next }
            if next.streamIndex == 1, landing.firstAudio == nil { landing.firstAudio = next.pts }
            if next.streamIndex == 0, landing.firstVideo == nil { landing.firstVideo = next.pts }
        }
        return landing
    }

    @Test("a hit on a keyframe inside a long audio block also returns that block's audio",
          arguments: [Store.disk, .memory])
    func lastKeyframeAnchor(store: Store) throws {
        let (source, root) = try cachedSource(Self.wideInterleave(), store: store, anchorsOnLastKeyframe: true)
        defer { source.close(); try? FileManager.default.removeItem(at: root) }

        let landing = try seek(source, to: 15.0)
        #expect(landing.hit)
        // Before the fix: first audio 20_000, five seconds of silence.
        #expect(landing.firstAudio.map { $0 >= 14_500 && $0 <= 15_000 } ?? false,
                "first audio=\(String(describing: landing.firstAudio))")
        // The audio comes from records ahead of the keyframe; the video there is not delivered.
        #expect(landing.firstVideo == 15_000)
    }

    @Test("the previous-keyframe anchor keeps its GOP of preroll and gains the audio")
    func previousKeyframeAnchor() throws {
        let (source, root) = try cachedSource(Self.wideInterleave(), anchorsOnLastKeyframe: false)
        defer { source.close(); try? FileManager.default.removeItem(at: root) }

        let landing = try seek(source, to: 15.0)
        #expect(landing.hit)
        #expect(landing.firstAudio.map { $0 >= 14_500 && $0 <= 15_000 } ?? false,
                "first audio=\(String(describing: landing.firstAudio))")
        #expect(landing.firstVideo == 10_000)
    }

    @Test("ordinary interleave with a GOP of preroll restores exactly where it did")
    func fineInterleaveUnchanged() throws {
        let (source, root) = try cachedSource(Self.fineInterleave(), anchorsOnLastKeyframe: false)
        defer { source.close(); try? FileManager.default.removeItem(at: root) }

        let landing = try seek(source, to: 15.0)
        #expect(landing.hit)
        #expect(landing.firstPacket?.streamIndex == 0)
        #expect(landing.firstPacket?.pts == 10_000)
        #expect(landing.firstAudio == 10_000)
    }

    @Test("ordinary interleave on the last keyframe gains only the decoder lead of audio")
    func fineInterleaveLastKeyframe() throws {
        let (source, root) = try cachedSource(Self.fineInterleave(), anchorsOnLastKeyframe: true)
        defer { source.close(); try? FileManager.default.removeItem(at: root) }

        let landing = try seek(source, to: 15.0)
        #expect(landing.hit)
        #expect(landing.firstAudio.map { $0 >= 14_500 && $0 < 15_000 } ?? false,
                "first audio=\(String(describing: landing.firstAudio))")
        #expect(landing.firstVideo == 15_000)
    }

    @Test("audio without a restart point declines the hit instead of landing silent")
    func noAudioRestartPointIsAMiss() throws {
        let (source, root) = try cachedSource(Self.wideInterleave(audioKey: false), anchorsOnLastKeyframe: true)
        defer { source.close(); try? FileManager.default.removeItem(at: root) }

        let landing = try seek(source, to: 15.0)
        #expect(!landing.hit)
    }

    @Test("a skip left by one seek does not reach into the next")
    func skipBelongsToItsSeek() throws {
        let (source, root) = try cachedSource(Self.wideInterleave(), anchorsOnLastKeyframe: true)
        defer { source.close(); try? FileManager.default.removeItem(at: root) }

        // Take only the first audio packet, so most of the video skip is still pending.
        let token = source.beginSeek(to: 15.0)
        #expect(try source.prepareSeek(token, to: 15.0))
        source.endSeek(token, sourceClock: 15.0)
        #expect(try source.read()?.streamIndex == 1)

        // Seek back to 2 s: audio [0,10) precedes GOP 0, the restore starts in it, and the video
        // that follows must start at that seek's own keyframe, 0.
        let landing = try seek(source, to: 2.0)
        #expect(landing.hit)
        #expect(landing.firstAudio.map { $0 >= 1_500 && $0 <= 2_000 } ?? false,
                "first audio=\(String(describing: landing.firstAudio))")
        #expect(landing.firstVideo == 0)
    }
}
