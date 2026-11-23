import Foundation
import Testing
@testable import AetherEngine

/// A still extractor whose source cannot give a still (no video stream, no codec parameters, no
/// decoder for the codec) must not read the source again on the next request. Every open re-reads
/// the header, over HTTP from the origin, and a scrub asks many times a second.
struct FrameDecodeContextOpenFailureTests {

    /// Counts the reads that reach the source.
    private final class CountingReader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let lock = NSLock()
        private var position = 0
        private var readCount = 0

        init(bytes: Data) { self.bytes = bytes }

        var reads: Int { lock.withLock { readCount } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                readCount += 1
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
                case SEEK_CUR where position + Int(offset) >= 0 && position + Int(offset) <= bytes.count:
                    position += Int(offset)
                case SEEK_END where offset <= 0 && bytes.count + Int(offset) >= 0:
                    position = bytes.count + Int(offset)
                default: return -1
                }
                return Int64(position)
            }
        }

        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    /// A 0.1 s mono 16-bit PCM WAV: a valid source with an audio stream and no video stream.
    private static func audioOnlyWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let samples = Data(count: Int(sampleRate) / 10 * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        data.append(samples)
        return data
    }

    @Test("a source with no video stream is read once, and later opens fail without reading it")
    func permanentFailureIsRemembered() {
        let reader = CountingReader(bytes: Self.audioOnlyWAV())
        let context = FrameDecodeContext(reader: reader, formatHint: "wav")
        defer { context.close() }

        #expect(throws: FrameDecodeError.self) { try context.ensureOpen() }
        let readsAfterFirstOpen = reader.reads
        #expect(readsAfterFirstOpen > 0, "the first open read the source")

        for _ in 0..<5 {
            do {
                try context.ensureOpen()
                Issue.record("the open succeeded on a source with no video stream")
            } catch {
                #expect("\(error)" == "\(FrameDecodeError.noVideoStream)")
            }
        }
        #expect(reader.reads == readsAfterFirstOpen, "later opens did not read the source again")
        #expect(!context.isOpen)
    }

    @Test("only failures the source itself causes are permanent")
    func permanentFailureClassification() {
        #expect(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.noVideoStream))
        #expect(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.noCodecParameters))
        #expect(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.unsupportedCodec))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.allocationFailed))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.decoderOpenFailed))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(DemuxerError.openFailed(code: -1)))
    }
}
