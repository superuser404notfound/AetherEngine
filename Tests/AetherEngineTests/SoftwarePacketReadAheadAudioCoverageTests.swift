import Foundation
import Testing
@testable import AetherEngine

/// Matroska TrueHD reaches the read-ahead with no packet duration and millisecond timestamps that
/// repeat (0.83 ms frames on a 1/1000 time base). The duration model rejected every such packet, so
/// audio coverage stayed empty, the combined A/V frontier was nil, and no seek ever hit the packet
/// cache: on the TV every TrueHD seek, even back to a spot just played, refetched from the source.
@Suite("Software VOD read-ahead audio coverage without durations")
struct SoftwarePacketReadAheadAudioCoverageTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    /// 25 fps video (40 ticks) interleaved with 1200 Hz audio frames on a 1/1000 time base, 4 s,
    /// then EOF. `audioGapAt` (seconds) drops one second of audio there.
    private func runToEnd(audioDuration: Int64, audioGapAt: Double? = nil) throws -> SoftwarePacketReadAhead {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var packets: [SoftwareStoredPacket] = []
        var audioFrame = 0
        for picture in 0..<100 {
            let videoPTS = Int64(picture * 40)
            packets.append(SoftwareStoredPacket(
                pts: videoPTS, dts: videoPTS, duration: 40, position: 0, streamIndex: 0, flags: 0x1,
                timeBaseNumerator: 1, timeBaseDenominator: 1000, bytes: Data(repeating: 7, count: 64),
                sideData: []))
            // 48 audio frames of 1/1200 s per 40 ms picture.
            for _ in 0..<48 {
                let seconds = Double(audioFrame) / 1200
                audioFrame += 1
                if let gap = audioGapAt, seconds >= gap, seconds < gap + 1 { continue }
                let audioPTS = Int64((seconds * 1000).rounded(.down))
                packets.append(SoftwareStoredPacket(
                    pts: audioPTS, dts: audioPTS, duration: audioDuration, position: 0, streamIndex: 1,
                    flags: 0x1, timeBaseNumerator: 1, timeBaseDenominator: 1000,
                    bytes: Data(repeating: 3, count: 16), sideData: []))
            }
        }
        let counter = Counter()
        let all = packets
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: .init(index: 1, numerator: 1, denominator: 1000),
            byteBudget: 64 << 20, forwardSeconds: 100, initialSourceClock: 0, fifo: fifo
        ) { _ in
            let index = counter.next() - 1
            return index < all.count ? all[index] : nil
        }
        source.start()
        let deadline = Date().addingTimeInterval(10)
        while !source.snapshot.sourceEnded, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(source.snapshot.sourceEnded)
        return source
    }

    private func seekHits(_ source: SoftwarePacketReadAhead, to seconds: Double) throws -> Bool {
        let token = source.beginSeek(to: seconds)
        return try source.prepareSeek(token, to: seconds)
    }

    @Test("duration-less, repeating-millisecond audio still makes a retained seek a cache hit")
    func durationlessAudioHits() throws {
        let source = try runToEnd(audioDuration: 0)
        defer { source.close() }
        #expect(try seekHits(source, to: 2.0))
    }

    @Test("audio with durations keeps hitting as before")
    func durationAudioHits() throws {
        let source = try runToEnd(audioDuration: 1)
        defer { source.close() }
        #expect(try seekHits(source, to: 2.0))
    }

    @Test("a real hole in duration-less audio is not bridged")
    func audioHoleMisses() throws {
        let source = try runToEnd(audioDuration: 0, audioGapAt: 1.5)
        defer { source.close() }
        #expect(try seekHits(source, to: 2.0) == false)
    }
}


@Suite(.timeLimit(.minutes(3)), .offCooperativePool)
struct QuantizedAudioReadAheadTests {
    private final class Index: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; defer { value += 1 }; return value }
    }

    @Test("quantized audio ranges, frontier and retained seeks agree", arguments: [false, true], [false, true])
    func realStores(memory: Bool, missingPacket: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func packet(_ pts: Int64, stream: Int32 = 0, duration: Int64 = 33, bytes: Int = 64) -> SoftwareStoredPacket {
            .init(pts: pts, dts: pts, duration: duration, position: 0, streamIndex: stream, flags: 1,
                  timeBaseNumerator: 1, timeBaseDenominator: 1000, bytes: Data(repeating: 7, count: bytes), sideData: [])
        }
        var packets = (0..<360).map { packet(Int64($0) * 1000 / 30) }
        for i: Int64 in 0..<259 where !missingPacket || i != 50 {
            packets.append(packet(i * 2048 * 1000 / 44100, stream: 1, duration: 46, bytes: 371))
        }
        let all = packets.sorted { $0.pts < $1.pts }
        let index = Index()
        let store: any SoftwarePacketStore = memory
            ? SoftwarePacketMemoryFIFO(historyCapBytes: 8 << 20)
            : try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true, parentDirectory: root)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: .init(index: 1, numerator: 1, denominator: 1000,
                         audioTiming: .init(sampleRate: 44100, layout: .fixed(samples: 2048, packetBytes: 371))),
            byteBudget: 8 << 20, forwardSeconds: 100, initialSourceClock: 0, fifo: store, videoReorderDepth: 1
        ) { _ in let i = index.next(); return i < all.count ? all[i] : nil }
        defer { source.close() }
        source.start()
        try await waitFor { source.snapshot.sourceEnded }
        // All records remain in the non-purgeable forward queue: this does not assume consumed
        // memory history survives memory pressure (the separate FIFO suites cover that contract).
        let ranges = source.residentRanges
        #expect(ranges.count == (missingPacket ? 2 : 1))
        #expect((source.snapshot.frontier ?? 0) > (missingPacket ? 2 : 11))
        let target = 2.35
        #expect(ranges.contains { $0.contains(target) } == !missingPacket)
        let token = source.beginSeek(to: target)
        #expect(try source.prepareSeek(token, to: target) == !missingPacket)
        if !missingPacket {
            let backwards = source.beginSeek(to: 1)
            #expect(try source.prepareSeek(backwards, to: 1))
            #expect(source.snapshot.sourceEpoch == 0)
        }
        _ = source.beginSeek()
        #expect(source.residentRanges.isEmpty)
        #expect(source.snapshot.frontier == nil)
    }
}

struct SoftwareAudioPacketCoverageTests {
    func ranges(_ model: SoftwareAudioPacketCoverage, denominator: Int32 = 1000) -> [ClosedRange<Double>] {
        model.rangesSeconds(timeBaseNumerator: 1, timeBaseDenominator: denominator)
    }
    @Test("sample geometry bridges quantization without hiding holes or phase drift")
    func rationalCoverage() {
        // Fixed sample geometry is shared by AAC, AC-3, MPEG audio and non-reservoir WMA.
        // These are timing fixtures, not codec/file playback acceptance.
        for (samples, rate) in [(1024, 44100), (960, 48000), (1536, 44100), (1152, 44100),
                                (576, 22050), (2048, 44100), (512, 16000), (1024, 32000)] {
            for denominator: Int32 in [1000, 90000, Int32(rate)] {
                let timing = SoftwareAudioPacketTiming(sampleRate: Int32(rate), layout: .fixed(samples: Int32(samples), packetBytes: nil))
                var model = SoftwareAudioPacketCoverage(timeBaseNumerator: 1, timeBaseDenominator: denominator, timing: timing)
                let duration = Int64(samples) * Int64(denominator) / Int64(rate)
                for i: Int64 in 0..<12_000 {
                    let pts = i * Int64(samples) * Int64(denominator) / Int64(rate)
                    model.insert(pts: pts, duration: duration, byteCount: 371)
                }
                #expect(ranges(model, denominator: denominator).count == 1, "sample clock fragmented")
                let end = ranges(model, denominator: denominator)[0].upperBound
                #expect(end > 100, "range cap truncated long run")
                model.reset()
                #expect(ranges(model, denominator: denominator).isEmpty)
            }
        }
        let rationalTiming = SoftwareAudioPacketTiming(sampleRate: 44100, layout: .fixed(samples: 2048, packetBytes: nil))
        var rational = SoftwareAudioPacketCoverage(timeBaseNumerator: 1001, timeBaseDenominator: 44_100_000, timing: rationalTiming)
        for i: Int64 in 0..<2000 {
            rational.insert(pts: i * 2048 * 1000 / 1001, duration: 2048 * 1000 / 1001, byteCount: 371)
        }
        #expect(rational.rangesSeconds(timeBaseNumerator: 1001, timeBaseDenominator: 44_100_000).count == 1)
        var integralGap = SoftwareAudioPacketCoverage(timeBaseNumerator: 1, timeBaseDenominator: 1000,
            timing: .init(sampleRate: 48000, layout: .fixed(samples: 1536, packetBytes: nil)))
        integralGap.insert(pts: 0, duration: 32, byteCount: 371)
        integralGap.insert(pts: 33, duration: 32, byteCount: 371)
        #expect(ranges(integralGap).count == 2, "an integral clock has no quantization gap to excuse")
        var phaseGap = SoftwareAudioPacketCoverage(timeBaseNumerator: 1, timeBaseDenominator: 1000, timing: rationalTiming)
        for i: Int64 in 0..<2000 {
            phaseGap.insert(pts: i * 2048 * 1000 / 44100 + (i >= 1000 ? 1 : 0), duration: 46, byteCount: 371)
        }
        #expect(ranges(phaseGap).count == 2, "a real one-tick phase jump after a locked cadence must survive")
        let wma = SoftwareAudioPacketTiming(sampleRate: 44100, layout: .fixed(samples: 2048, packetBytes: 371))
        func make(_ timing: SoftwareAudioPacketTiming? = wma) -> SoftwareAudioPacketCoverage {
            .init(timeBaseNumerator: 1, timeBaseDenominator: 1000, timing: timing)
        }
        var valid = make()
        for pts: Int64 in [0, 46, 92, 139, 185] { valid.insert(pts: pts, duration: 46, byteCount: 371) }
        #expect(ranges(valid).count == 1)
        var unknown = make(nil)
        for pts: Int64 in [0, 46, 92, 139, 185] { unknown.insert(pts: pts, duration: 46, byteCount: 371) }
        #expect(ranges(unknown).count == 2, "unknown positive durations must remain strict")
        var wrongSize = make()
        for pts: Int64 in [0, 46, 92, 139, 185] { wrongSize.insert(pts: pts, duration: 46, byteCount: 742) }
        #expect(ranges(wrongSize).count == 2, "packed/reservoir payload cannot inherit fixed sample geometry")
        var drift = make()
        for i: Int64 in 0..<100 { drift.insert(pts: 47 * i, duration: 46, byteCount: 371) }
        #expect(ranges(drift).count > 30, "one tick per packet must not be swallowed")
        var hole = make()
        hole.insert(pts: 0, duration: 46, byteCount: 371)
        hole.insert(pts: 47, duration: 46, byteCount: 371)
        hole.insert(pts: 140, duration: 46, byteCount: 371)
        #expect(!ranges(hole).contains { $0.contains(0.12) }, "missing packet bridged")
        var invalid = make()
        invalid.insert(pts: 0, duration: 46, byteCount: 371)
        invalid.insert(pts: Int64.min, duration: 46, byteCount: 371)
        invalid.insert(pts: 47, duration: 46, byteCount: 371)
        #expect(ranges(invalid).count == 2, "missing PTS did not break evidence")
        var legacy = make(nil)
        for pts: Int64 in [0, 0, 1, 2, 2, 3, 1000, 1001] { legacy.insert(pts: pts, duration: 0, byteCount: 40) }
        #expect(ranges(legacy).count == 2)
        #expect(!ranges(legacy).contains { $0.contains(0.5) })
        // Implicit HE-AAC: codecpar says 1024 samples, every packet holds 2048, no packet a duration.
        var understated = make(.init(sampleRate: 48000, layout: .fixed(samples: 1024, packetBytes: nil)))
        for i: Int64 in 0..<200 { understated.insert(pts: i * 2048 * 1000 / 48000, duration: 0, byteCount: 371) }
        #expect(ranges(understated).count == 1, "failed geometry dropped duration-less successor coverage")
        var straddle = make(nil)
        for pts: Int64 in [Int64.min + 1, Int64.max - 1] { straddle.insert(pts: pts, duration: 0, byteCount: 40) }
        #expect(ranges(straddle).isEmpty, "an overflowing successor difference invented coverage")
        var overflow = make()
        for pts: Int64 in [Int64.min + 1, Int64.max - 100, 0, -100, Int64.max] {
            overflow.insert(pts: pts, duration: 46, byteCount: 371)
        }
        var badTimebase = SoftwareAudioPacketCoverage(timeBaseNumerator: 0, timeBaseDenominator: 1, timing: wma)
        badTimebase.insert(pts: 0, duration: 46, byteCount: 371)
        #expect(ranges(badTimebase).isEmpty)
        let pcm = SoftwareAudioPacketTiming(sampleRate: 44100, layout: .pcm(bytesPerSampleFrame: 4))
        #expect(pcm.samples(byteCount: 4096) == 1024 && pcm.samples(byteCount: 4097) == nil)
        var mismatch = make()
        mismatch.insert(pts: 0, duration: 20, byteCount: 371)
        mismatch.insert(pts: 47, duration: 46, byteCount: 371)
        #expect(ranges(mismatch).count == 2)
        let last = ranges(valid).last!.upperBound
        #expect(abs(last - 0.231) < 0.000001, "final packet invents unverified coverage")
    }
}
