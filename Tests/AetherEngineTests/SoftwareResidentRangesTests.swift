import Foundation
import Testing
@testable import AetherEngine

@Suite("Software VOD resident ranges", .timeLimit(.minutes(3)))
struct SoftwareResidentRangesTests {
    private final class Input: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [SoftwareStoredPacket]
        private var index = 0
        init(_ packets: [SoftwareStoredPacket]) { self.packets = packets }
        func next() -> SoftwareStoredPacket? {
            lock.lock(); defer { lock.unlock() }
            guard index < packets.count else { return nil }
            defer { index += 1 }; return packets[index]
        }
    }
    private func packet(_ pts: Int64, stream: Int32 = 0, duration: Int64 = 40,
                        key: Bool = true) -> SoftwareStoredPacket {
        .init(pts: pts, dts: pts, duration: duration, position: 0, streamIndex: stream,
              flags: key ? 1 : 0, timeBaseNumerator: 1, timeBaseDenominator: 1000,
              bytes: Data(repeating: 7, count: 100), sideData: [])
    }
    private func source(_ packets: [SoftwareStoredPacket], audio: Bool = false,
                        reorder: Int? = nil, budget: Int = 1_000_000,
                        chunkBytes: Int = 1024,
                        store: (any SoftwarePacketStore)? = nil) throws -> SoftwarePacketReadAhead {
        let input = Input(packets)
        let fifo = try store ?? SoftwarePacketDiskFIFO(chunkTargetBytes: chunkBytes, retainConsumed: true)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: audio ? .init(index: 1, numerator: 1, denominator: 1000) : nil,
            byteBudget: budget, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo, videoReorderDepth: reorder) { _ in input.next() }
        source.start()
        return source
    }

    @Test("Backward and forward cache hits preserve the same spans through begin, prepare and settle")
    func cachedSeeks() async throws {
        let source = try source((0..<100).map { packet(Int64($0) * 40) })
        defer { source.close() }
        try await waitFor { source.snapshot.sourceEnded }
        #expect(source.residentRanges == [0...4])
        for target in [3.0, 1, 2.5, 0.5] {
            source.updatePlayhead(target)
            let token = source.beginSeek(to: target)
            #expect(source.residentRanges == [0...4])
            #expect(try source.prepareSeek(token, to: target))
            #expect(source.residentRanges == [0...4])
            source.endSeek(token, sourceClock: target)
            #expect(source.residentRanges == [0...4])
        }
        let miss = source.beginSeek(to: 8)
        #expect(try !source.prepareSeek(miss, to: 8))
        #expect(source.residentRanges.isEmpty)
        source.close()
        #expect(source.residentRanges.isEmpty)
    }

    @Test("Required audio intersects video, keeps holes, and missing selected audio proves nothing")
    func audioIntersection() async throws {
        let video = (0..<100).map { packet(Int64($0) * 40) }
        let audio = [packet(500, stream: 1, duration: 500), packet(2000, stream: 1, duration: 1000)]
        let source = try source(video + audio, audio: true)
        defer { source.close() }
        try await waitFor { source.snapshot.sourceEnded }
        #expect(source.residentRanges == [0.5...1, 2...3])
        let missing = try self.source(video, audio: true)
        defer { missing.close() }
        try await waitFor { missing.snapshot.sourceEnded }
        #expect(missing.residentRanges.isEmpty)
    }

    @Test("Successor PTS retains reorder semantics, a discontinuity, and no invented final frame")
    func reorderedVideo() async throws {
        let pts: [Int64] = [0, 120, 40, 80, 160, 2000, 2120, 2040, 2080]
        let source = try source(pts.map { packet($0, duration: 0) }, reorder: 4)
        defer { source.close() }
        try await waitFor { source.snapshot.sourceEnded }
        #expect(source.residentRanges == [0...0.16, 2...2.12])
        let invalid = try self.source(([Int64](stride(from: 0, to: 2000, by: 40)) + [0])
            .map { packet($0) }, reorder: 4)
        defer { invalid.close() }
        try await waitFor { invalid.snapshot.sourceEnded }
        #expect(invalid.residentRanges.isEmpty)
    }

    @Test("Real FIFO eviction shortens backward coverage without changing the read bytes")
    func diskEviction() async throws {
        let packets = (0..<100).map { packet(Int64($0) * 40) }
        let source = try source(packets, budget: 1400, chunkBytes: 512)
        defer { source.close() }
        let retained = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SoftwareStoredPacket], Error>) in
                Thread.detachNewThread {
                    do {
                        var values: [SoftwareStoredPacket] = []
                        while let packet = try source.read() {
                            values.append(packet)
                            source.updatePlayhead(Double(packet.pts) / 1000)
                        }
                        continuation.resume(returning: values)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { source.close() }
        #expect(retained == packets)
        try await waitFor { source.snapshot.sourceEnded }
        let spans = source.residentRanges
        #expect(!spans.isEmpty)
        #expect((spans.first?.lowerBound ?? 0) > 3)
        #expect(spans.last?.upperBound == 4)
        let miss = source.beginSeek(to: 0.1)
        #expect(try !source.prepareSeek(miss, to: 0.1))
        #expect(source.residentRanges.isEmpty)
    }

    @Test("History the kernel emptied in the memory store leaves the published spans (#759)")
    func purgedMemoryHistory() async throws {
        let packets = (0..<400).map { packet(Int64($0) * 40) }
        let store = SoftwarePacketMemoryFIFO(chunkTargetBytes: 1, historyCapBytes: .max, kernelMayPurge: false)
        let source = try source(packets, store: store)
        defer { source.close() }
        try await consume(source, expecting: packets, fails: false)
        #expect(source.residentRanges.last?.upperBound == 16)
        store.purgeHistoryForTesting()
        let spans = source.residentRanges
        #expect((spans.first?.lowerBound ?? 0) > 0)
        #expect(spans.last?.upperBound == 16)
        let miss = source.beginSeek(to: 0.1)
        #expect(try !source.prepareSeek(miss, to: 0.1))
    }

    @Test("Evicted reordered timestamps and metadata pressure only shorten coverage")
    func residencyWatermarks() {
        var value = SoftwarePacketResidency(maximumChunks: 2)
        value.insert(chunkID: 0, pts: 900, duration: 40, numerator: 1, denominator: 1000, isVideo: true)
        value.insert(chunkID: 1, pts: 100, duration: 40, numerator: 1, denominator: 1000, isVideo: true)
        value.insert(chunkID: 1, pts: 1100, duration: 40, numerator: 1, denominator: 1000, isVideo: false)
        value.evict(before: 1)
        #expect(value.videoFloor == 0.94)
        #expect(value.audioFloor == -.infinity)
        value.insert(chunkID: 2, pts: 1200, duration: 0, numerator: 1, denominator: 1000, isVideo: true)
        value.insert(chunkID: 3, pts: 1300, duration: 0, numerator: 1, denominator: 1000, isVideo: true)
        #expect(value.videoFloor == 0.94)
        #expect(value.audioFloor == 1.14)
        value.evict(before: 4)
        #expect(value.videoFloor == 1.301)
    }

    @Test("Invalid discarded timestamps fail closed and reset begins a separate residency lifetime")
    func invalidWatermark() {
        var value = SoftwarePacketResidency()
        value.insert(chunkID: 0, pts: .max, duration: 40, numerator: 1, denominator: 1000, isVideo: true)
        value.evict(before: 1)
        #expect(value.videoFloor == .infinity)
        value = SoftwarePacketResidency()
        #expect(value.videoFloor == -.infinity)
    }

    private func consume(_ source: SoftwarePacketReadAhead,
                         expecting packets: [SoftwareStoredPacket], fails: Bool) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Thread.detachNewThread {
                    do {
                        for expected in packets { #expect(try source.read() == expected) }
                        if fails { #expect(throws: SourceFailure.self) { _ = try source.read() } }
                        else { #expect(try source.read() == nil) }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { source.close() }
    }

    private enum SourceFailure: Error { case unavailable }
    private final class FailingInput: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [SoftwareStoredPacket]
        private var index = 0
        private var failAtEnd = true
        let reachedEnd = DispatchSemaphore(value: 0)
        let releaseEnd = DispatchSemaphore(value: 0)
        init(_ packets: [SoftwareStoredPacket]) { self.packets = packets }
        func next() throws -> SoftwareStoredPacket? {
            lock.lock()
            if index < packets.count {
                let packet = packets[index]; index += 1
                lock.unlock(); return packet
            }
            let fail = failAtEnd
            lock.unlock()
            if fail {
                reachedEnd.signal(); releaseEnd.wait()
                throw SourceFailure.unavailable
            }
            return nil
        }
        func replace(_ packets: [SoftwareStoredPacket]) {
            lock.lock(); defer { lock.unlock() }
            self.packets = packets; index = 0; failAtEnd = false
        }
    }

    @Test("A source failure preserves committed coverage and cached seeks, but never becomes EOF",
           arguments: [false, true])
    func retainedAfterSourceFailure(reordered: Bool) async throws {
        let packets = (0..<100).map { packet(Int64($0) * 40, key: $0 == 0) }
        let input = FailingInput(packets)
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: nil, byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo, videoReorderDepth: reordered ? 4 : nil) { _ in try input.next() }
        defer { input.releaseEnd.signal(); source.close() }
        source.start()
        try await waitFor { input.reachedEnd.wait(timeout: .now()) == .success }
        let before = source.residentRanges
        #expect(!before.isEmpty)
        let epoch = source.snapshot.sourceEpoch
        input.releaseEnd.signal()
        try await waitFor { source.producerParkedForTesting }
        #expect(source.producerParkedForTesting)
        #expect(!source.snapshot.sourceEnded)
        #expect(source.residentRanges == before)
        // A failure cannot flush unresolved successor PTS as though it proved a normal EOF.
        if reordered { #expect((before.last?.upperBound ?? 4) < 3.96) }
        try await consume(source, expecting: packets, fails: true)
        for target in [0.5, 2.0, 1.0] {
            let token = source.beginSeek(to: target)
            #expect(try source.prepareSeek(token, to: target))
            source.endSeek(token, sourceClock: target)
            #expect(source.snapshot.sourceEpoch == epoch)
            #expect(source.residentRanges == before)
            try await consume(source, expecting: packets, fails: true)
            #expect(!source.snapshot.sourceEnded)
        }
        // A miss still resets the failed source lifetime and accepts only the new epoch's data.
        let replacement = (0..<100).map { packet(10_000 + Int64($0) * 40, key: $0 == 0) }
        let miss = source.beginSeek(to: 10)
        #expect(try !source.prepareSeek(miss, to: 10))
        #expect(source.residentRanges.isEmpty)
        input.replace(replacement)
        source.endSeek(miss, sourceClock: 10)
        try await waitFor { source.snapshot.sourceEnded }
        #expect(source.snapshot.sourceEpoch == epoch + 1)
        #expect(source.residentRanges.first?.lowerBound == 10)
        try await consume(source, expecting: replacement, fails: false)
    }

    @Test("A storage append failure still invalidates retained coverage and cached seeks")
    func storageFailureRemainsClosed() async throws {
        let packets = (0..<10).map { packet(Int64($0) * 40) }
        let input = Input(packets)
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: nil, byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo) { _ in
                if let packet = input.next() { return packet }
                reached.signal(); release.wait()
                return packets[0]
            }
        defer { release.signal(); source.close() }
        source.start()
        try await waitFor { reached.wait(timeout: .now()) == .success }
        #expect(source.residentRanges == [0...0.4])
        try fifo.close()
        release.signal()
        try await waitFor { source.producerParkedForTesting }
        #expect(source.producerParkedForTesting)
        #expect(!source.snapshot.sourceEnded)
        #expect(source.residentRanges.isEmpty)
        let miss = source.beginSeek(to: 0.1)
        #expect(try !source.prepareSeek(miss, to: 0.1))
        #expect(source.snapshot.cacheSeekHits == 0)
    }

    @Test("Source origin mapping preserves gaps, clips negatives and rejects unknown origins")
    func displayMapping() {
        let spans = [90.0...105, 110...120]
        #expect(SoftwarePlaybackHost.displayResidentRanges(spans, sessionZeroSeconds: 100) == [0...5, 10...20])
        #expect(SoftwarePlaybackHost.displayResidentRanges(spans, sessionZeroSeconds: .nan).isEmpty)
        #expect(SoftwarePlaybackHost.displayResidentRanges(spans, sessionZeroSeconds: 200).isEmpty)
    }

    @Test("Large inexact timestamps do not manufacture display ranges")
    func exactness() {
        var coverage = SoftwarePacketCoverage()
        coverage.insert(pts: 9_007_199_254_740_993, duration: 4)
        #expect(coverage.rangesSeconds(timeBaseNumerator: 1, timeBaseDenominator: 1).isEmpty)
    }
}

@MainActor
@Suite("Software resident range publication", .timeLimit(.minutes(3)))
struct SoftwareResidentRangePublicationTests {
    private nonisolated static func isMainThread() -> Bool {
        Thread.isMainThread
    }

    @Test("Residency sampling leaves both main and the cooperative executor")
    @available(visionOS 2, *)
    func samplingExecutor() async {
        let publisher = SoftwareResidentRangePublication()
        var received: [ClosedRange<Double>] = []
        let work = publisher.sample {
            let label = String(cString: __dispatch_queue_get_label(nil))
            #expect(!Self.isMainThread())
            #expect(!label.contains("cooperative"), "residency read ran on \(label)")
            return [1...2]
        } publish: { received = $0 }
        await work?.value
        #expect(received == [1...2])
    }

    private actor Gate {
        private(set) var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { waiter = $0; entered = true }
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    @Test("A delayed sampler leaves main responsive, coalesces ticks, and cannot publish after seek/stop")
    func delayedSnapshots() async throws {
        let publisher = SoftwareResidentRangePublication()
        let gate = Gate()
        var received: [[ClosedRange<Double>]] = []
        let old = publisher.sample {
            await gate.wait()
            return [0...100]
        } publish: { received.append($0) }
        #expect(publisher.sample({ [0...999] }, publish: { received.append($0) }) == nil)
        try await waitFor { await gate.entered }
        // This main-actor turn can run while the background read is suspended. A new seek or stop
        // invalidates it; a new session/seek can immediately publish without waiting for that read.
        publisher.invalidate()
        let replacement = publisher.sample({ [200...220] }, publish: { received.append($0) })
        await replacement?.value
        #expect(received == [[200...220]])
        await gate.release()
        await old?.value
        #expect(received == [[200...220]])
    }

    @Test("Paused growth, eviction and a reset publish without a clock tick")
    func pausedUpdates() async {
        let publisher = SoftwareResidentRangePublication()
        var received: [[ClosedRange<Double>]] = []
        for spans: [ClosedRange<Double>] in [[10...30], [10...60], [20...60], [], [80...90]] {
            let work = publisher.sample({ spans }, publish: { received.append($0) })
            await work?.value
        }
        #expect(received == [[10...30], [10...60], [20...60], [], [80...90]])
    }
}
