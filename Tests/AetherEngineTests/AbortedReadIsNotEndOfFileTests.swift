import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Audit SEG-104 (A), demuxer half: the abort of a parked read (`markClosed()`) is reported by
/// Matroska, TS and fMP4 as end of file, and `readDemuxedPacketLocked` returned it as nil, which every
/// consumer reads as "the source ended". A demuxer that has been closed never reports that: the read
/// throws, so an aborted read cannot be mistaken for a real end of file.
@Suite("An aborted read is not the end of the source", .serialized)
struct AbortedReadIsNotEndOfFileTests {

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

    private final class ReadOutcome: @unchecked Sendable {
        enum Kind: Sendable { case endOfFile, threw }
        private let lock = NSLock()
        private var _kind: Kind?
        var kind: Kind? { lock.withLock { _kind } }
        func finish(_ kind: Kind) { lock.withLock { _kind = kind } }
    }

    /// The SimpleBlock boundary the Issue234 fixture's open never reads past, so the parked read
    /// comes back as a clean end of file rather than a torn element.
    private static let parkOffset = 2237

    private func fixture() throws -> Data {
        try #require(Data(base64Encoded: Issue234SideReaderSeekAnchorTests.fixtureBase64,
                          options: .ignoreUnknownCharacters))
    }

    private func drain(_ demuxer: Demuxer, into outcome: ReadOutcome) {
        Thread.detachNewThread {
            do {
                while let read = try demuxer.readPacket() {
                    var packet: UnsafeMutablePointer<AVPacket>? = read
                    trackedPacketFree(&packet)
                }
                outcome.finish(.endOfFile)
            } catch {
                outcome.finish(.threw)
            }
        }
    }

    @Test("a failed read is the source's end only while nobody has closed the demuxer")
    func readFailureClassification() {
        #expect(Demuxer.readFailureCode(FFmpegErr.eof, closeRequested: false) == nil,
                "a real end of file must stay the end of the source")
        #expect(Demuxer.readFailureCode(FFmpegErr.eof, closeRequested: true) == FFmpegErr.exit,
                "an end of file on a closed demuxer is the abort, not the source's")
        for code in [FFmpegErr.eio, FFmpegErr.invalidData, FFmpegErr.exit, -1] {
            #expect(Demuxer.readFailureCode(code, closeRequested: false) == code)
            #expect(Demuxer.readFailureCode(code, closeRequested: true) == code)
        }
    }

    @Test("a read that the close aborts throws instead of reporting the end of the source",
          .timeLimit(.minutes(3)))
    func abortedReadThrows() async throws {
        let reader = ParkingReader(try fixture())
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "matroska")
        defer { demuxer.close() }
        reader.arm(blockAt: Self.parkOffset)

        let outcome = ReadOutcome()
        drain(demuxer, into: outcome)
        try await waitFor { reader.isParked }
        demuxer.markClosed()
        reader.release()
        try await waitFor { outcome.kind != nil }

        #expect(outcome.kind == .threw, "the aborted read was reported as the end of the source")
    }

    @Test("the end of a source nobody closed is still the end of the source",
          .timeLimit(.minutes(3)))
    func realEndOfFileIsStillNil() async throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: ParkingReader(try fixture()), formatHint: "matroska")
        defer { demuxer.close() }

        let outcome = ReadOutcome()
        drain(demuxer, into: outcome)
        try await waitFor { outcome.kind != nil }

        #expect(outcome.kind == .endOfFile)
    }
}
