import Foundation
import Testing
@testable import AetherEngine

/// Audit SEG-104 (A): the pump checked for a stop only before it read. A read already in flight when
/// the session stopped the producer (the #79 restart aborts it with `markClosed`, which Matroska, TS
/// and fMP4 report as end of file) came back as source EOF, and the abandoned pump adopted its
/// half-written segment into the cache under the full index, where a later backward seek hits it.
@Suite("A stopped pump does not act on its in-flight read", .serialized)
struct StoppedPumpInFlightReadTests {

    /// Serves the fixture a few bytes at a time and, once armed, parks the read that reaches
    /// `blockAt` until released, then answers it with end of file.
    private final class ParkingReader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let condition = NSCondition()
        private var position = 0
        private var blockAt: Int?
        private var parked = false
        private var released = false

        init(_ bytes: Data) { self.bytes = bytes }

        func arm(blockAt offset: Int) { condition.withLock { blockAt = offset } }
        var isParked: Bool { condition.withLock { parked } }
        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            condition.lock()
            defer { condition.unlock() }
            if let blockAt, position >= blockAt {
                parked = true
                while !released { condition.wait() }
                return 0
            }
            var n = min(Int(size), 64, bytes.count - position)
            if let blockAt { n = min(n, blockAt - position) }
            guard n > 0 else { return 0 }
            bytes.withUnsafeBytes { raw in _ = memcpy(buffer, raw.baseAddress! + position, n) }
            position += n
            return Int32(n)
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            condition.withLock {
                switch whence {
                case 65536: return Int64(bytes.count)
                case SEEK_SET: position = Int(max(0, min(offset, Int64(bytes.count))))
                case SEEK_CUR: position = max(0, min(position + Int(offset), bytes.count))
                case SEEK_END: position = max(0, min(bytes.count + Int(offset), bytes.count))
                default: return -1
                }
                return Int64(position)
            }
        }

        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    private final class Exit: @unchecked Sendable {
        private let lock = NSLock()
        private var _reason: HLSSegmentProducer.PumpExitReason?
        func set(_ r: HLSSegmentProducer.PumpExitReason) { lock.withLock { _reason = r } }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.withLock { _reason } }
    }

    /// Start of the SimpleBlock element carrying the 7.2 s frame of the Issue234 fixture (15 s of
    /// H.264 at 5 fps in Matroska): past everything the open's stream probe reads, and on an element
    /// boundary, so the parked read comes back as a clean end of file rather than a torn element.
    private static let parkOffset = 2237

    @Test("a read that returns end of file after stop() exits as a stop and adopts nothing",
          .timeLimit(.minutes(3)))
    func eofAfterStopAdoptsNothing() async throws {
        let data = try #require(Data(base64Encoded: Issue234SideReaderSeekAnchorTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let reader = ParkingReader(data)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "matroska")
        defer { demuxer.close() }
        reader.arm(blockAt: Self.parkOffset)

        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        defer { cache.close() }
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: videoIndex,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                         timeBase: stream.pointee.time_base, codecTagOverride: nil),
            cache: cache, videoFallbackDurationPts: 200, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, 15_000])
        let exit = Exit()
        producer.onPumpFinished = { exit.set($0) }
        producer.start()

        try await waitFor { reader.isParked }
        #expect(producer.packetsWrittenCount > 0, "the segment in flight has to be partly written")
        producer.stop()
        reader.release()
        try await waitFor { exit.reason != nil }

        let reason = try #require(exit.reason)
        var exitedAsStop = false
        if case .stopRequested = reason { exitedAsStop = true }
        #expect(exitedAsStop, "a stopped pump exited as \(reason)")
        #expect(cache.count == 0, "the abandoned pump adopted its partial segment")
    }
}
