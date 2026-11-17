import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// SUB-201 / SUB-R201: the native subtitle readers read with `try? demuxer.readPacket()`, so a
/// transport error looked like EOF. In whole-program mode the stores were then marked finished and a
/// truncated .vtt was served as complete. The #151 prefetcher got the distinction in #231; both loops
/// now share `SideReaderLoop.readNext`.
@Suite("Native subtitle reader read errors", .serialized, .timeLimit(.minutes(3)))
struct NativeSubtitleReaderReadErrorTests {

    private static func fixture() -> Data {
        let events = (0..<4_000).map { (ms: 1_000 + $0 * 100, durationMs: 500) }
        return MatroskaSubtitleFixture.make(durationMs: 500_000, events: events)
    }

    @Test("a read error is reported as a failed read, not as the end of the source")
    func readNextClassifiesTheError() throws {
        let data = Self.fixture()
        let reader = FailingFromPositionReader(data: data, failFrom: data.count / 2)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "matroska")
        defer { demuxer.close() }

        var packets = 0
        var sawFailure = false
        loop: while true {
            switch SideReaderLoop.readNext(demuxer) {
            case .packet(let pkt):
                packets += 1
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            case .failed: sawFailure = true; break loop
            case .endOfFile: break loop
            }
        }
        #expect(sawFailure, "a transport error must not read as EOF (read \(packets) packets)")
    }

    @Test("a whole-program read that hits a transport error is a readFailed, never a finished store")
    @MainActor
    func wholeProgramReadFailureIsNotCompletion() async throws {
        let data = Self.fixture()
        let engine = try AetherEngine()
        let store = NativeSubtitleCueStore()
        let outcome = await engine.runNativeSubtitleReaders(
            url: URL(string: "https://s/movie.mkv")!,
            reader: FailingFromPositionReader(data: data, failFrom: data.count * 7 / 10),
            formatHint: "matroska", headers: [:], headerStore: nil,
            pairs: [(streamIndex: 0, store: store)],
            startAt: 0, videoWidth: 1920, videoHeight: 1080, readToEOF: true)

        #expect(outcome.exit == .readFailed)
        #expect(outcome.exit.isRestartable)
        #expect(outcome.cues > 0, "the cues read before the failure are kept")
        #expect(outcome.resumeSeconds != nil)
        #expect(!store.isFinished)

        var budget = Self.budget()
        let next = AetherEngine.nativeReaderDisposition(
            outcome, readToEOF: true, budget: &budget, cancelled: false)
        #expect(next == .restart(backoffNanoseconds: 1_000_000_000))
    }

    @Test("a whole-program read that reaches the real end is an endOfFile that finishes the stores")
    @MainActor
    func wholeProgramEOFFinishes() async throws {
        let engine = try AetherEngine()
        let store = NativeSubtitleCueStore()
        let events = (0..<50).map { (ms: 1_000 + $0 * 100, durationMs: 500) }
        let data = MatroskaSubtitleFixture.make(durationMs: 20_000, events: events)
        let outcome = await engine.runNativeSubtitleReaders(
            url: URL(string: "https://s/movie.mkv")!,
            reader: FailingFromPositionReader(data: data, failFrom: Int.max),
            formatHint: "matroska", headers: [:], headerStore: nil,
            pairs: [(streamIndex: 0, store: store)],
            startAt: 0, videoWidth: 1920, videoHeight: 1080, readToEOF: true)

        #expect(outcome.exit == .endOfFile)
        #expect(store.cueCount == 50)
        var budget = Self.budget()
        #expect(AetherEngine.nativeReaderDisposition(
            outcome, readToEOF: true, budget: &budget, cancelled: false) == .markFinished)
    }

    @Test("the supervisor restarts within the budget, then gives up without finishing")
    func dispositionBudget() {
        var budget = Self.budget(maxConsecutive: 2, maxRestarts: 8)
        let failed = AetherEngine.NativeSubtitleReaderOutcome(exit: .readFailed, cues: 0, resumeSeconds: nil)
        #expect(AetherEngine.nativeReaderDisposition(
            failed, readToEOF: true, budget: &budget, cancelled: false)
            == .restart(backoffNanoseconds: 1_000_000_000))
        #expect(AetherEngine.nativeReaderDisposition(
            failed, readToEOF: true, budget: &budget, cancelled: false)
            == .restart(backoffNanoseconds: 2_000_000_000))
        #expect(AetherEngine.nativeReaderDisposition(
            failed, readToEOF: true, budget: &budget, cancelled: false) == .giveUp)
    }

    @Test("a lazy reader's EOF finishes nothing, and cancellation or a failed open never restarts")
    func dispositionOtherExits() {
        var budget = Self.budget()
        func next(_ exit: SubtitleForwardPrefetcher.Exit, toEOF: Bool, cancelled: Bool = false)
        -> AetherEngine.NativeReaderDisposition {
            AetherEngine.nativeReaderDisposition(
                .init(exit: exit, cues: 0, resumeSeconds: nil),
                readToEOF: toEOF, budget: &budget, cancelled: cancelled)
        }
        #expect(next(.endOfFile, toEOF: false) == .stop)
        #expect(next(.cancelled, toEOF: true) == .stop)
        #expect(next(.openFailed, toEOF: true) == .stop)
        #expect(next(.readFailed, toEOF: true, cancelled: true) == .stop)
    }

    private static func budget(maxConsecutive: Int = 3, maxRestarts: Int = 8)
    -> SubtitleForwardPrefetcher.RestartBudget {
        SubtitleForwardPrefetcher.RestartBudget(
            maxConsecutiveFailures: maxConsecutive, maxRestarts: maxRestarts,
            backoffNanoseconds: 1_000_000_000)
    }
}

/// Serves `data` and fails every read at or past `failFrom` with a negative return (a transport
/// error, as opposed to 0, which is EOF at the custom reader boundary).
private final class FailingFromPositionReader: IOReader, @unchecked Sendable {
    private let data: Data
    private let failFrom: Int
    private var position = 0
    private let lock = NSLock()

    init(data: Data, failFrom: Int) {
        self.data = data
        self.failFrom = failFrom
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        if position >= failFrom { return -1 }
        guard position < data.count else { return 0 }
        let n = min(Int(size), data.count - position, failFrom - position)
        data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: n),
                       from: position..<(position + n))
        position += n
        return Int32(n)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return Int64(data.count) }
        lock.lock()
        defer { lock.unlock() }
        let target: Int
        switch whence {
        case SEEK_SET: target = Int(offset)
        case SEEK_CUR: target = position + Int(offset)
        case SEEK_END: target = data.count + Int(offset)
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = min(target, data.count)
        return Int64(position)
    }

    func close() {}
}
