import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// `Demuxer.stream(at:)` is called from the main actor while the demux thread sits inside
/// `av_read_frame`, which on MPEG-TS can reallocate the `streams` array (audit NAT-7). It answers
/// from a table copied under the demuxer's lock, so it neither indexes the live array nor waits out a
/// read that holds that lock for a whole network stall.
@Suite("Demuxer stream lookup")
struct DemuxerStreamLookupTests {

    /// A WAV source whose reads can be made to block, the way a network read parks.
    private final class GatedReader: IOReader, @unchecked Sendable {
        private let inner: DataIOReader
        private let lock = NSLock()
        private var armed = false
        private var _blocked = false
        private let gate = DispatchSemaphore(value: 0)

        init(data: Data) { inner = DataIOReader(data: data) }

        var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return _blocked }

        func arm() { lock.lock(); armed = true; lock.unlock() }

        func release() {
            lock.lock()
            armed = false
            lock.unlock()
            gate.signal()
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            lock.lock()
            let wait = armed
            if wait { _blocked = true }
            lock.unlock()
            if wait { gate.wait() }
            return inner.read(buffer, size: size)
        }

        func seek(offset: Int64, whence: Int32) -> Int64 { inner.seek(offset: offset, whence: whence) }
        func close() { inner.close() }
        func cancel() {}
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000, channels = 2
        let pcm = Data(count: Int(Double(sampleRate) * seconds) * channels * 2)
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    @Test("every opened stream is found, an index past them is not, and nothing is after close")
    func lookupFollowsTheOpenStreams() throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 1)))
        let audio = demuxer.audioStreamIndex
        try #require(audio >= 0)
        #expect(demuxer.stream(at: audio)?.pointee.index == audio)
        #expect(demuxer.stream(at: audio + 1) == nil)
        #expect(demuxer.stream(at: -1) == nil)
        demuxer.close()
        #expect(demuxer.stream(at: audio) == nil)
    }

    @Test("a lookup does not wait for a read that holds the demuxer", .timeLimit(.minutes(3)))
    func lookupDoesNotWaitOutARead() async throws {
        let reader = GatedReader(data: makeWAV(seconds: 20))
        let demuxer = Demuxer()
        try demuxer.open(reader: reader)
        let audio = demuxer.audioStreamIndex
        try #require(audio >= 0)
        reader.arm()

        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while let packet = try? demuxer.readPacket() {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&p)
            }
            done.signal()
        }
        try await waitFor { reader.isBlocked }

        #expect(demuxer.stream(at: audio)?.pointee.index == audio)

        demuxer.markClosed()
        reader.release()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                done.wait()
                continuation.resume()
            }
        }
        demuxer.close()
    }
}
