import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Packet admission tests use a synthetic HEVC demuxer; they do not qualify VC-1 decoding.
@Suite(.offCooperativePool, .timeLimit(.minutes(3)))
struct SoftwareVC1ReferencePrerollTests {
    private func source() throws -> Demuxer {
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        return dem
    }

    @Test("reference admission preserves the key packet for the actual decode/cache reader")
    func preservesKeyPacket() throws {
        let dem = try source()
        defer { dem.close() }
        let stream = try #require(dem.stream(at: dem.videoStreamIndex))
        let tb = stream.pointee.time_base
        let timeBase = Double(tb.num) / Double(tb.den)
        var expected: Int64?
        try dem.peekPackets(maxPackets: 1) { expected = $0.pointee.pts; return true }
        let ticks = try #require(expected)
        let pts = Double(ticks) * timeBase
        let admitted = try SoftwareVC1ReferencePreroll.findKeyframe(
            dem: dem, target: pts, videoIndex: dem.videoStreamIndex, timeBase: timeBase,
            deadline: .infinity, isCurrent: { true })
        #expect(admitted == pts)
        var packet = try dem.readPacket()
        defer { av_packet_free(&packet) }
        #expect(packet?.pointee.pts == ticks)
        #expect((try #require(packet)).pointee.flags & AV_PKT_FLAG_KEY != 0)
    }

    @Test("missing keys, EOF, expired time and byte/packet bounds never fail open",
          arguments: ["missing", "eof", "time", "bytes", "packets", "future"])
    func boundedFailure(reason: String) throws {
        let dem = try source()
        defer { dem.close() }
        if reason == "missing" {
            try dem.peekPackets(maxPackets: 128) { $0.pointee.flags &= ~AV_PKT_FLAG_KEY; return false }
        }
        do {
            _ = try SoftwareVC1ReferencePreroll.findKeyframe(
                dem: dem, target: reason == "future" ? -1 : 0,
                videoIndex: reason == "eof" ? -1 : dem.videoStreamIndex,
                timeBase: 1, deadline: reason == "time" ? -.infinity : .infinity,
                packetLimit: reason == "packets" ? 0 : 128,
                byteLimit: reason == "bytes" ? 1 : 1024 * 1024, isCurrent: { true })
            Issue.record("unusable reference source was accepted: \(reason)")
        } catch SoftwarePlaybackHost.HostError.repositionFailed { }
    }

    @Test("a cancelled preparation cannot reposition or admit a reference")
    func cancelled() throws {
        let dem = Demuxer()
        do {
            _ = try SoftwareVC1ReferencePreroll.prepare(dem: dem, target: 1390, origin: 600,
                                                    videoIndex: 0, timeBase: 1, isCurrent: { false })
            Issue.record("cancelled preparation returned")
        } catch is CancellationError { }
    }

    @Test("offset-origin targets keep the same before-target and bounded-GOP contract")
    func targetBoundary() {
        #expect(SoftwareVC1ReferencePreroll.acceptsKeyframe(pts: 1386, target: 1390))
        #expect(!SoftwareVC1ReferencePreroll.acceptsKeyframe(pts: 1390.001, target: 1390))
        #expect(!SoftwareVC1ReferencePreroll.acceptsKeyframe(pts: 1381, target: 1390))
        #expect(!SoftwareVC1ReferencePreroll.acceptsKeyframe(pts: .nan, target: 1390))
        #expect(!SoftwareVC1ReferencePreroll.acceptsKeyframe(pts: 1390, target: .infinity))
    }

    /// This is the load's real async cancellation boundary, with a source parked inside its
    /// positioning operation. Synthetic HEVC bytes exercise ownership/interruption only; they
    /// deliberately do not stand in for the missing public VC-1 picture fixture.
    @Test("cancelling an in-flight reference preparation interrupts the parked source")
    func cancelledDuringPreparation() async throws {
        let reader = try ParkedPositioningReader()
        let dem = Demuxer()
        try dem.open(reader: reader, formatHint: "mp4")
        defer { dem.close() }
        let work = Task {
            await SoftwareVC1ReferencePreroll.reposition(
                dem: dem, target: 5, origin: 0, videoIndex: dem.videoStreamIndex,
                timeBase: 1, budget: 30, queue: DispatchQueue(label: "vc1.cancel"),
                closesOnCancel: true, isSuperseded: { false },
                fallback: { dem, target, budget, queue, obsolete in
                    await dem.seekBounded(to: target, timeout: budget, on: queue, isSuperseded: obsolete)
                })
        }
        defer { work.cancel(); dem.markClosed() }
        try await waitFor { reader.enteredPositioning }
        #expect(!reader.wasCancelled)
        work.cancel()
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: { dem.markClosed() }
        #expect(result == .superseded)
        #expect(reader.wasCancelled)
    }

    @Test("an inconclusive probe restores the original target and propagates fallback failure",
          arguments: [true, false])
    func fallback(succeeds: Bool) async throws {
        let dem = try source()
        defer { dem.close() }
        let outcome = await SoftwareVC1ReferencePreroll.reposition(
            dem: dem, target: 0, origin: 0, videoIndex: -1, timeBase: 1,
            budget: 30, queue: DispatchQueue(label: "vc1.fallback"), closesOnCancel: false,
            isSuperseded: { false }, fallback: { dem, target, remaining, queue, obsolete in
                #expect(target == 0)
                #expect(remaining > 0 && remaining < 30)
                let result = await dem.seekBounded(to: target, timeout: remaining, on: queue,
                                                  isSuperseded: obsolete)
                #expect(result == .landed)
                return succeeds ? result : .stalled
            })
        #expect(outcome == (succeeds ? .landed : .stalled))
        var packet = try dem.readPacket()
        defer { av_packet_free(&packet) }
        #expect(packet != nil)
    }

    private final class Obsolete: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    @Test("cancelled or superseded transport preparation leaves the reusable source open",
          arguments: [false, true])
    func transportCancellation(supersede: Bool) async throws {
        let reader = try ParkedPositioningReader()
        let dem = Demuxer()
        try dem.open(reader: reader, formatHint: "mp4")
        defer { dem.close() }
        let obsolete = Obsolete()
        let queue = DispatchQueue(label: "vc1.transport")
        let work = Task {
            await SoftwareVC1ReferencePreroll.reposition(
                dem: dem, target: 5, origin: 0, videoIndex: dem.videoStreamIndex, timeBase: 1,
                budget: 30, queue: queue, closesOnCancel: false,
                isSuperseded: { obsolete.isSet }, fallback: { _, _, _, _, _ in
                    Issue.record("obsolete transport performed fallback")
                    return .landed
                })
        }
        defer { work.cancel(); reader.releasePositioning() }
        try await waitFor { reader.enteredPositioning }
        if supersede { obsolete.set() } else { work.cancel() }
        #expect(!reader.wasCancelled)
        reader.releasePositioning()
        #expect(await work.value == .superseded)
        #expect(!reader.wasCancelled)
        // A subsequent operation on the same serial queue must still reach the provider.
        #expect(await dem.seekBounded(to: 0, timeout: 1, on: queue) == .landed)
    }

    private final class ParkedPositioningReader: TimeSeekableIOReader, @unchecked Sendable {
        private let bytes: DataIOReader
        private let condition = NSCondition()
        private var entered = false
        private var cancelled = false
        private var released = false

        init() throws { bytes = DataIOReader(data: try ProbeTestFixtures.hdr10Plus()) }
        var mediaDuration: Double { 8 }
        var discImageProbeEnabled: Bool { false }
        var enteredPositioning: Bool { condition.withLock { entered } }
        var wasCancelled: Bool { condition.withLock { cancelled } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            bytes.read(buffer, size: size)
        }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            bytes.seek(offset: offset, whence: whence)
        }
        func seek(to seconds: Double) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            entered = true
            // No timer can turn this into a successful cancellation test: only the production
            // demux close -> reader.cancel path releases the parked positioning operation.
            while !cancelled && !released { condition.wait() }
            return !cancelled
        }
        func releasePositioning() {
            condition.withLock { released = true; condition.broadcast() }
        }
        func cancel() {
            condition.withLock { cancelled = true; condition.broadcast() }
        }
        func close() { cancel() }
    }

}
