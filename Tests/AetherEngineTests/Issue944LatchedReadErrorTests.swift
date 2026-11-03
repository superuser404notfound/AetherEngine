import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// AE#944 (hp561, 7.53.0): a subtitle side reader's positioning seek ran past its deadline, the cut
/// read left `pb->error` and `eof_reached` set on the AVIO context, and the byte-estimate fallback
/// "applied" over it: nothing in a byte-space seek clears either field, so the session's first read
/// replayed the stored -1 ("Operation not permitted") and the restart loop reopened until it gave up.
struct Issue944LatchedReadErrorTests {

    /// The fixture, with reads that fail while `failing` is set.
    private final class FlakyReader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let lock = NSLock()
        private var position = 0
        private var failingValue = false

        init(bytes: Data = TinyTransportStreamFixture.data) { self.bytes = bytes }

        var failing: Bool {
            get { lock.withLock { failingValue } }
            set { lock.withLock { failingValue = newValue } }
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                if failingValue { return -1 }
                let n = min(Int(size), bytes.count - position)
                guard n > 0 else { return 0 }
                bytes.withUnsafeBytes { raw in _ = memcpy(buffer, raw.baseAddress! + position, n) }
                position += n
                return Int32(n)
            }
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            lock.withLock {
                switch whence {
                case 0x10000: return Int64(bytes.count)  // AVSEEK_SIZE
                case SEEK_SET where offset >= 0 && offset <= Int64(bytes.count): position = Int(offset)
                case SEEK_CUR where offset == 0: break
                default: return -1
                }
                return Int64(position)
            }
        }

        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    /// Reads until the demuxer stops handing out packets; true when it stopped on an error rather
    /// than at the end of the source.
    private func drainEndsInError(_ demuxer: Demuxer) -> (packets: Int, failed: Bool) {
        var packets = 0
        for _ in 0..<10_000 {
            do {
                guard let packet = try demuxer.readPacket() else { return (packets, false) }
                packets += 1
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&owned)
            } catch {
                return (packets, true)
            }
        }
        return (packets, false)
    }

    @Test("a failed read does not outlive a byte-estimate reposition")
    func byteEstimateClearsLatchedError() throws {
        let reader = FlakyReader()
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts")
        defer { demuxer.close() }

        reader.failing = true
        #expect(drainEndsInError(demuxer).failed, "the failing read has to latch first")
        reader.failing = false

        #expect(demuxer.seekByteEstimate(to: 0, knownDuration: 8, timeout: 5))
        let after = drainEndsInError(demuxer)
        #expect(after.packets > 0)
        #expect(after.failed == false, "the source is healthy again; only the stored error could fail it")
    }

    @Test("a failed read does not outlive a bounded reposition")
    func boundedSeekClearsLatchedError() throws {
        let reader = FlakyReader()
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts")
        defer { demuxer.close() }

        reader.failing = true
        #expect(drainEndsInError(demuxer).failed, "the failing read has to latch first")
        reader.failing = false

        _ = demuxer.seekBounded(to: 1.4, timeout: 5)
        let after = drainEndsInError(demuxer)
        #expect(after.packets > 0)
        #expect(after.failed == false, "the source is healthy again; only the stored error could fail it")
    }

    /// The 7.54.0 retest: Matroska keeps its own end-of-stream latch (`MatroskaDemuxContext.done`),
    /// set when a failed read sends `matroska_resync` into EOF. A timestamp seek resets it, a byte
    /// seek does not, so a byte-estimate landing after a deadline-cut read handed the side reader
    /// EOF at second 0 of the file and the prefetcher stopped as if the source had ended.
    @Test("a failed Matroska read does not end the source after a byte-estimate reposition")
    func byteEstimateClearsMatroskaEndLatch() throws {
        let events = (0..<20).map { (ms: $0 * 10_000, durationMs: 2_000) }
        let reader = FlakyReader(bytes: MatroskaSubtitleFixture.make(durationMs: 200_000, events: events))
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "matroska")
        defer { demuxer.close() }

        reader.failing = true
        _ = drainEndsInError(demuxer)
        reader.failing = false

        #expect(demuxer.seekByteEstimate(to: 0, knownDuration: 200, timeout: 5))
        let after = drainEndsInError(demuxer)
        #expect(after.packets == events.count, "every cue is still in the source")
        #expect(after.failed == false)
    }

    @Test("a closed demuxer keeps its error and skips the fallback")
    func closedDemuxerSkipsFallback() throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: FlakyReader(), formatHint: "mpegts")
        defer { demuxer.close() }
        demuxer.markClosed()
        #expect(demuxer.seekByteEstimate(to: 0, knownDuration: 8, timeout: 5) == false)
        #expect(demuxer.seekBounded(to: 1.4, timeout: 5) == false)
    }
}
