import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import AetherEngine

@Suite("Still request cancellation", .timeLimit(.minutes(3)))
struct FrameExtractorCancellationTests {
    @Test("Cancelling the first still request still closes its idle decode context", arguments: [false, true])
    func cancelledFirstRequestClosesIdleContext(resident: Bool) async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = resident
            ? FrameExtractor(residentReader: reader, formatHint: "mpegts", identity: "resident-idle")
            : FrameExtractor(reader: reader, formatHint: "mpegts")
        await extractor.setIdleIntervalForTesting(.milliseconds(200))
        reader.arm()
        let pending = Task { () -> Bool in
            if resident {
                return await extractor.residentPreview(
                    rawTarget: 2, refined: true, maxWidth: 16, isCancelled: { false }) != nil
            }
            return await extractor.preview(at: 2, maxWidth: 16) != nil
        }
        defer { reader.release(); pending.cancel() }
        try await waitFor { reader.isBlocked }
        // Only Demuxer.close cancels the reader, so the count is sampled before the idle task can
        // run: sampled after the request returns, a close that already fired was never counted.
        let cancellations = reader.cancellationCount
        pending.cancel()
        reader.release()
        #expect(await pending.value == false)
        // Keep the extractor alive while its idle task releases the context; dropping the
        // extractor would hide the leak.
        try await waitFor { reader.cancellationCount > cancellations }
        await extractor.shutdown()
    }

    @Test("A yielding request still closes the first decode's idle context")
    func yieldedFirstRequestClosesIdleContext() async throws {
        let starved = Mutex(false)
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts",
                                       yieldWhile: { starved.withLock { $0 } })
        await extractor.setIdleIntervalForTesting(.milliseconds(200))
        reader.arm()
        let older = Task { await extractor.preview(at: 2, maxWidth: 16) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        // The yielding request starts the idle countdown while the older decode is still gated, so
        // the close can land before that decode returns. Sampled here, it is counted either way.
        let cancellations = reader.cancellationCount
        starved.withLock { $0 = true }
        #expect(await extractor.preview(at: 25, maxWidth: 16) == nil)
        reader.release()
        #expect(await older.value == nil)
        try await waitFor { reader.cancellationCount > cancellations }
        await extractor.shutdown()
    }

    @Test("A resident cache hit supersedes an older refined decode")
    func residentCacheHitSupersedesRefinement() async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data(), maxReadSize: 1_024)
        let extractor = FrameExtractor(residentReader: reader, formatHint: "mpegts", identity: "resident-cancellation",
                                       residentBudget: .seconds(60))
        let cached = try #require(await extractor.residentPreview(
            rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false }))
        reader.arm()
        let older = Task { await extractor.residentPreview(
            rawTarget: 12, refined: true, maxWidth: 16, isCancelled: { false }) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        let hit = await extractor.residentPreview(
            rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false })
        #expect(hit?.image === cached.image)
        reader.release()
        #expect(await older.value == nil, "a cached resident request must retire the previous refinement")
        await extractor.shutdown()
    }

    @Test("Rejected resident requests leave another caller's valid refinement alone")
    func rejectedResidentRequestsDoNotSupersedeRefinement() async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data(), maxReadSize: 1_024)
        let extractor = FrameExtractor(residentReader: reader, formatHint: "mpegts", identity: "resident-guards",
                                       residentBudget: .seconds(60))
        _ = try #require(await extractor.residentPreview(
            rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false }))
        reader.arm()
        let older = Task { await extractor.residentPreview(
            rawTarget: 12, refined: true, maxWidth: 16, isCancelled: { false }) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        #expect(await extractor.residentPreview(
            rawTarget: .nan, refined: false, maxWidth: 16, isCancelled: { false }) == nil)
        #expect(await extractor.residentPreview(
            rawTarget: 2, refined: false, maxWidth: 0, isCancelled: { false }) == nil)
        #expect(await extractor.residentPreview(
            rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { true }) == nil)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await extractor.residentPreview(
                rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false })
        }
        #expect(await cancelled.value == nil)
        reader.release()
        #expect(await older.value != nil)
        await extractor.shutdown()
    }

    @Test("A cache hit supersedes an older decode", arguments: [FrameMode.thumbnail, .preview, .snapshot])
    func cacheHitSupersedesDecode(mode: FrameMode) async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts")
        let cached = try #require(await request(extractor, mode: mode, seconds: 2))
        reader.arm()
        let older = Task { await request(extractor, mode: mode, seconds: 22) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        let hit = await request(extractor, mode: mode, seconds: 2)
        #expect(hit === cached)
        reader.release()
        #expect(await older.value == nil, "a superseded request must not publish its late frame")
        await extractor.shutdown()
    }

    @Test("Cancelling the caller discards a decode waiting on I/O")
    func callerCancellation() async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts")
        reader.arm()
        let pending = Task { await extractor.preview(at: 2, maxWidth: 16) }
        defer { reader.release(); pending.cancel() }
        try await waitFor { reader.isBlocked }
        pending.cancel()
        reader.release()
        #expect(await pending.value == nil)
        #expect(await extractor.preview(at: 2, maxWidth: 16) != nil,
                "cancellation must not poison a later request")
        await extractor.shutdown()
    }

    @Test("An already-cancelled caller cannot receive a cached frame")
    func cancelledCacheHit() async throws {
        let extractor = FrameExtractor(reader: DataIOReader(data: try LongGOPTransportStreamFixture.data()),
                                       formatHint: "mpegts")
        _ = try #require(await extractor.preview(at: 2, maxWidth: 16))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await extractor.preview(at: 2, maxWidth: 16)
        }
        #expect(await cancelled.value == nil)
        #expect(await extractor.preview(at: 2, maxWidth: 16) != nil)
        await extractor.shutdown()
    }

    @Test("A yielded preview retires an older decode without starting another")
    func yieldedRequestSupersedesDecode() async throws {
        let starved = Mutex(false)
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts",
                                       yieldWhile: { starved.withLock { $0 } })
        _ = try #require(await extractor.preview(at: 2, maxWidth: 16))
        reader.arm()
        let older = Task { await extractor.preview(at: 22, maxWidth: 16) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        starved.withLock { $0 = true }
        #expect(await extractor.preview(at: 25, maxWidth: 16) == nil)
        reader.release()
        #expect(await older.value == nil)
        await extractor.shutdown()
    }

    @Test("A cancelled cache request leaves another caller's valid decode alone")
    func cancelledRequestDoesNotSupersedeDecode() async throws {
        let reader = StillGateReader(data: try LongGOPTransportStreamFixture.data())
        let extractor = FrameExtractor(reader: reader, formatHint: "mpegts")
        _ = try #require(await extractor.preview(at: 2, maxWidth: 16))
        reader.arm()
        let older = Task { await extractor.preview(at: 22, maxWidth: 16) }
        defer { reader.release(); older.cancel() }
        try await waitFor { reader.isBlocked }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await extractor.preview(at: 2, maxWidth: 16)
        }
        #expect(await cancelled.value == nil)
        reader.release()
        #expect(await older.value != nil)
        await extractor.shutdown()
    }

    private func request(_ extractor: FrameExtractor, mode: FrameMode, seconds: Double) async -> CGImage? {
        switch mode {
        case .thumbnail: await extractor.thumbnail(at: seconds, maxWidth: 16)
        case .preview: await extractor.preview(at: seconds, maxWidth: 16)
        case .snapshot: await extractor.snapshot(at: seconds, maxSize: CGSize(width: 16, height: 16))
        }
    }
}

/// The production decode queue blocks at a real source operation, while the extractor actor can
/// accept a newer request. The condition protects only this one-shot gate; DataIOReader owns its cursor.
private final class StillGateReader: IOReader, @unchecked Sendable {
    private let reader: DataIOReader
    // Short reads let a resident refinement cross the AVIO buffer and reach the real I/O gate.
    private let maxReadSize: Int32
    private let condition = NSCondition()
    private var armed = false
    private var blocked = false
    private var released = false
    private var cancellations = 0

    init(data: Data, maxReadSize: Int32 = .max) {
        reader = DataIOReader(data: data)
        self.maxReadSize = maxReadSize
    }
    var discImageProbeEnabled: Bool { false }
    var isBlocked: Bool {
        condition.lock(); defer { condition.unlock() }
        return blocked
    }
    var cancellationCount: Int {
        condition.lock(); defer { condition.unlock() }
        return cancellations
    }
    func arm() {
        condition.lock(); defer { condition.unlock() }
        armed = true
        blocked = false
        released = false
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
    private func waitAtGate() {
        condition.lock(); defer { condition.unlock() }
        guard armed else { return }
        armed = false
        blocked = true
        while !released { condition.wait() }
    }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        waitAtGate()
        return reader.read(buffer, size: min(size, maxReadSize))
    }
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence != 65536 { waitAtGate() }
        return reader.seek(offset: offset, whence: whence)
    }
    func cancel() {
        condition.lock(); cancellations += 1; condition.unlock()
        release()
    }
    func close() { release(); reader.close() }
}
