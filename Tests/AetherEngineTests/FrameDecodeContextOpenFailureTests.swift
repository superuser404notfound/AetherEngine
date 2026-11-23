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
        /// Returned instead of EOF once the bytes run out, standing in for a dropped connection.
        private let endError: Int32?
        private let lock = NSLock()
        private var position = 0
        private var readCount = 0

        init(bytes: Data, endError: Int32? = nil) {
            self.bytes = bytes
            self.endError = endError
        }

        var reads: Int { lock.withLock { readCount } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                readCount += 1
                let n = min(Int(size), bytes.count - position)
                guard n > 0 else { return endError ?? 0 }
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

    /// An FLV whose header announces audio and video, followed by 20 PCM audio tags and no video
    /// tag. FLV makes its streams from the tags, so the audio stream resolves and
    /// `avformat_find_stream_info` returns success without a video stream, whether the input ended
    /// there or a read failed there.
    private static func audioThenCutFLV() -> Data {
        var data = Data([0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00])
        let payload = [UInt8](repeating: 0, count: 882)  // 10 ms of 44.1 kHz 16-bit mono
        let dataSize = 1 + payload.count
        for index in 0..<20 {
            let ms = index * 10
            data.append(contentsOf: [0x08, UInt8(dataSize >> 16), UInt8(dataSize >> 8 & 0xFF), UInt8(dataSize & 0xFF),
                                     UInt8(ms >> 16 & 0xFF), UInt8(ms >> 8 & 0xFF), UInt8(ms & 0xFF), 0x00,
                                     0x00, 0x00, 0x00])
            data.append(0x3E)  // PCM little endian, 44.1 kHz, 16-bit, mono
            data.append(contentsOf: payload)
            let tagSize = 11 + dataSize
            data.append(contentsOf: [UInt8(tagSize >> 24), UInt8(tagSize >> 16 & 0xFF), UInt8(tagSize >> 8 & 0xFF),
                                     UInt8(tagSize & 0xFF)])
        }
        return data
    }

    @Test("a read error before the video stream showed up is retried, not kept as no video")
    func cutShortAnalysisIsRetried() {
        let reader = CountingReader(bytes: Self.audioThenCutFLV(), endError: -5)  // AVERROR(EIO)
        let context = FrameDecodeContext(reader: reader, formatHint: "flv")
        defer { context.close() }

        do {
            try context.ensureOpen()
            Issue.record("the open succeeded on a source with no video tag")
        } catch {
            #expect("\(error)" == "\(FrameDecodeError.streamAnalysisCutShort)")
        }
        let readsAfterFirstOpen = reader.reads
        _ = reader.seek(offset: 0, whence: SEEK_SET)
        #expect(throws: FrameDecodeError.self) { try context.ensureOpen() }
        #expect(reader.reads > readsAfterFirstOpen, "the second open read the source again")
    }

    @Test("the same source read to its end is kept as no video")
    func analysisToTheEndIsKept() {
        let reader = CountingReader(bytes: Self.audioThenCutFLV())
        let context = FrameDecodeContext(reader: reader, formatHint: "flv")
        defer { context.close() }

        do {
            try context.ensureOpen()
            Issue.record("the open succeeded on a source with no video tag")
        } catch {
            #expect("\(error)" == "\(FrameDecodeError.noVideoStream)")
        }
        let readsAfterFirstOpen = reader.reads
        #expect(throws: FrameDecodeError.self) { try context.ensureOpen() }
        #expect(reader.reads == readsAfterFirstOpen, "the second open did not read the source")
    }

    @Test("a source failure is final only when the stream analysis ran to one of its own limits")
    func sourceFailureClassification() {
        func report(_ stop: ProbeReport.Stop) -> ProbeReport {
            ProbeReport(stop: stop, unresolved: 0, programs: 0, pmtMissing: 0,
                        headerWaitReleasedAfter: nil, probeBytes: 0, closeToReturn: nil)
        }
        let retried = "\(FrameDecodeError.streamAnalysisCutShort)"
        for failure in [FrameDecodeError.noVideoStream, .unsupportedCodec] {
            for stop in [ProbeReport.Stop.resolved, .probesize, .analyzeduration, .eof] {
                #expect("\(FrameDecodeContext.sourceFailure(failure, probe: report(stop)))" == "\(failure)",
                        "\(failure) after \(stop)")
            }
            for stop in [ProbeReport.Stop.readError, .stopped, .interrupted] {
                #expect("\(FrameDecodeContext.sourceFailure(failure, probe: report(stop)))" == retried,
                        "\(failure) after \(stop)")
            }
            #expect("\(FrameDecodeContext.sourceFailure(failure, probe: nil))" == retried, "\(failure), no report")
        }
    }

    @Test("only failures the source itself causes are permanent")
    func permanentFailureClassification() {
        #expect(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.noVideoStream))
        #expect(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.noCodecParameters))
        #expect(FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.unsupportedCodec))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.allocationFailed))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.decoderOpenFailed))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.parametersCopyFailed(-12)))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(FrameDecodeError.streamAnalysisCutShort))
        #expect(!FrameDecodeContext.isPermanentOpenFailure(DemuxerError.openFailed(code: -1)))
    }
}
