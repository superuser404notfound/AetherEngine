import Testing
import Foundation
@testable import AetherEngine

/// AE#958: an origin whose 206 names the requested range over a body from somewhere else is caught
/// on the first reconnect that starts inside bytes the reader holds, before any of that body is read.
@Suite("Fabricated range origins", .offCooperativePool)
struct FabricatedRangeOriginTests {

    private static let size: Int64 = 128 * 1024 * 1024
    private static let chunk = 1024 * 1024

    /// Reads forward in 1 MiB steps until `limit` or the first failed read, checking every byte
    /// against the pattern. Returns how far it got, whether a read failed, and the first offset
    /// whose byte was not the source's.
    private func readForward(_ reader: AVIOReader, limit: Int64) -> (read: Int64, failed: Bool, wrongAt: Int64?) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        var pos: Int64 = 0
        while pos < limit {
            let n = reader.read(into: buf, size: Int32(Self.chunk))
            guard n > 0 else { return (pos, true, nil) }
            for i in 0..<Int(n) where buf[i] != ThrottledOriginServer.patternByte(at: pos + Int64(i)) {
                return (pos, false, pos + Int64(i))
            }
            pos += Int64(n)
        }
        return (pos, false, nil)
    }

    @Test("an honest origin is re-read for the check and plays on unchanged", .timeLimit(.minutes(3)))
    func honestOriginPassesTheCheck() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: Self.size, patternedBody: true))
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/honest-958.bin")!
        // The refill under test is the one at the end of the first bounded range. An origin that
        // outruns this byte-checking read hits the window's high water first, and that reconnect
        // lands wherever the read stood, so the window is set above what the test reads.
        let reader = AVIOReader(url: url, windowHighWater: 64 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let limit = AVIOReader.persistentRangeBytes + 8 * 1024 * 1024
        let result = readForward(reader, limit: limit)
        #expect(result.wrongAt == nil, "wrong byte at \(result.wrongAt ?? -1)")
        #expect(!result.failed, "the read failed at \(result.read)")
        #expect(result.read >= limit)
        let refill = AVIOReader.persistentRangeBytes - Int64(AVIOReader.rangeCheckBytes)
        #expect(server.requestLog.contains { $0.start == refill },
                "no refill asked from \(refill): \(server.requestLog.map(\.start))")
        #expect(!FabricatedRangeOrigins.caughtRecently(url, within: 60))
    }

    @Test("a 206 carrying another chunk's bytes fails the read before any of them is returned",
          .timeLimit(.minutes(3)))
    func fabricatedRangeIsCaughtAtTheRefill() async throws {
        let chunkAlign: Int64 = 8 * 1024 * 1024
        let size = Self.size
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            // The tail prefetch is a side request the check does not cover; leave it honest.
            guard offset > 0, offset < size / 2 else { return .serve206 }
            return .serve206Fabricated(bodyFrom: offset - offset % chunkAlign)
        }
        let server = try #require(ThrottledOriginServer(totalSize: size, patternedBody: true, respond: respond))
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/timeshift-958.ts")!
        let reader = AVIOReader(url: url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let result = readForward(reader, limit: AVIOReader.persistentRangeBytes + 8 * 1024 * 1024)
        #expect(result.wrongAt == nil, "a fabricated byte reached the demuxer at \(result.wrongAt ?? -1)")
        #expect(result.failed, "the reads ran on to \(result.read) over a fabricated range")
        #expect(result.read <= AVIOReader.persistentRangeBytes)
        #expect(FabricatedRangeOrigins.caughtRecently(url, within: 60))
    }

    /// The field shape: the parse jumps to the tail, playback returns to the retained head and reads
    /// past it, and the reconnect at the head's end is the first request that can be checked. The
    /// read that leaves the head is also the one that drops it, so its last bytes have to outlive it.
    @Test("the reconnect at the end of the retained head is checked on a held connection",
          .timeLimit(.minutes(3)))
    func reconnectAtTheHeadEndIsChecked() async throws {
        let chunkAlign: Int64 = 8 * 1024 * 1024
        let size = Self.size
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            guard offset > 0, offset < size - chunkAlign else { return .serve206 }
            return .serve206Fabricated(bodyFrom: offset - offset % chunkAlign)
        }
        let server = try #require(ThrottledOriginServer(totalSize: size, patternedBody: true, respond: respond))
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/held-958.ts")!
        let reader = AVIOReader(url: url, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        let headEnd = Int64(AVIOReader.headSpanMaxBytes)
        var read: Int64 = 0
        while read < headEnd {
            let n = reader.read(into: buf, size: Int32(64 * 1024))
            try #require(n > 0, "the head did not arrive")
            read += Int64(n)
        }
        // Outside the speculative tail fetch, so the excursion is a reconnect, as the field's was.
        let excursion = size - 1024 * 1024
        #expect(reader.seek(offset: excursion, whence: SEEK_SET) == excursion)
        #expect(reader.read(into: buf, size: Int32(64 * 1024)) > 0)
        reader.markOpenPhaseFinished()

        #expect(reader.seek(offset: 0, whence: SEEK_SET) == 0)
        let result = readForward(reader, limit: headEnd + 4 * 1024 * 1024)
        #expect(result.wrongAt == nil, "a fabricated byte reached the demuxer at \(result.wrongAt ?? -1)")
        #expect(result.failed, "the reads ran on to \(result.read) over a fabricated range")
        #expect(result.read <= headEnd)
        let check = headEnd - Int64(AVIOReader.rangeCheckBytes)
        #expect(server.requestLog.contains { $0.start == check },
                "no checked reconnect at the head's end: \(server.requestLog.map(\.start))")
        // Deliberately immediate: a failed read must already have published its cause.
        // Waiting for the registry would hide the wake-before-record race in AVIOReader.
        #expect(FabricatedRangeOrigins.caughtRecently(url, within: 60))
    }

    @Test("the probe holds delivery back until its overlap is complete")
    func probeOutcomes() {
        let expected = Data((0..<64).map { UInt8($0) })
        var honest = RangeHonestyProbe(generation: 1, start: 100, expected: expected)
        #expect(honest.absorb(expected.prefix(40)) == .pending)
        let rest = expected.suffix(24) + Data([0xAA, 0xBB])
        #expect(honest.absorb(rest) == .honoured(released: Data([0xAA, 0xBB])))

        var lying = RangeHonestyProbe(generation: 1, start: 100, expected: expected)
        let other = Data(repeating: 0x47, count: 80)
        #expect(lying.absorb(other) == .fabricated(received: other))
    }

    @Test("only the generic source failures are renamed, and only for a caught origin")
    func reclassification() {
        for kind in [PlaybackErrorKind.sourceOpenFailed, .vodSourceFailed, .softwarePipelineFailed] {
            let info = PlaybackErrorInfo(kind: kind, message: "Source read failed")
            #expect(AetherEngine.reclassifiedForFabricatedRanges(info, caught: true).kind == .sourceFabricatesRanges)
            #expect(AetherEngine.reclassifiedForFabricatedRanges(info, caught: false) == info)
        }
        let refused = PlaybackErrorInfo(kind: .sourceRefused, message: "HTTP 403", underlyingCode: 403)
        #expect(AetherEngine.reclassifiedForFabricatedRanges(refused, caught: true) == refused)
    }

    @Test("a caught origin explains failures for a while, then no longer")
    func registryWindow() {
        let url = URL(string: "http://origin.invalid/registry-958.ts")!
        let at = Date(timeIntervalSince1970: 1_000_000)
        FabricatedRangeOrigins.record(url, now: at)
        #expect(FabricatedRangeOrigins.caughtRecently(url, within: 60, now: at.addingTimeInterval(30)))
        #expect(!FabricatedRangeOrigins.caughtRecently(url, within: 60, now: at.addingTimeInterval(61)))
    }
}
