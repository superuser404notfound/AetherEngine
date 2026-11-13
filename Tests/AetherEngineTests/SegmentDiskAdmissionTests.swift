import Foundation
import Testing
@testable import AetherEngine

@Suite("Total segment disk admission", .timeLimit(.minutes(3)))
struct SegmentDiskAdmissionTests {
    private func status(_ cache: SegmentCache) -> SessionCacheStatus {
        cache.status(route: .loopbackFMP4, requestedBudgetBytes: 100,
                     baseEffectiveBudgetBytes: 100, volumeSafetyLimitBytes: nil)
    }

    @Test("Reservation plus residents never exceeds the cap across forward and backward seeks")
    func seekHistoryIsBounded() {
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 20,
                                 retentionBudgetBytes: 100_000, hardDiskLimitBytes: 600)
        defer { cache.close() }
        for index in Array(0...50) + Array(5...35) + Array(100...150) {
            cache.declareTarget(index)
            #expect(cache.store(index: index, data: Data(repeating: UInt8(index % 256), count: 100)))
            #expect(status(cache).currentDiskBytes <= 600)
            #expect(cache.peek(index: index)?.count == 100)
        }
        #expect(status(cache).evictionCount > 0)
    }

    @Test("Staging is counted before writes and transfers once on adoption")
    func stageReservationTransfers() throws {
        let cache = SegmentCache(hardDiskLimitBytes: 600)
        defer { cache.close() }
        cache.declareTarget(0)
        let path = cache.sessionDir.appendingPathComponent("staging-test.tmp")
        #expect(cache.admitStagingWrite(path: path, bytes: 300))
        #expect(status(cache).stagingBytes == 300)
        #expect(status(cache).currentDiskBytes == 300)
        try Data(repeating: 7, count: 300).write(to: path)
        #expect(cache.adopt(index: 0, stagingPath: path, byteCount: 300))
        #expect(status(cache).stagingBytes == 0)
        #expect(status(cache).currentResidentBytes == 300)
        #expect(status(cache).currentDiskBytes == 300)
    }

    @Test("Oversized and foreign writes are rejected before disk writes")
    func refusesImpossibleWrites() {
        let cache = SegmentCache(hardDiskLimitBytes: 500)
        defer { cache.close() }
        cache.declareTarget(0)
        #expect(!cache.store(index: 0, data: Data(count: 501)))
        #expect(!cache.admitStagingWrite(path: URL(fileURLWithPath: "/tmp/foreign.tmp"), bytes: 1))
        #expect(cache.totalBytes == 0)
        #expect(status(cache).stagingBytes == 0)
    }

    @Test("A full forward band parks until consumer advancement frees history")
    func waitsAndReleases() async throws {
        let cache = SegmentCache(forwardWindow: 4, hardDiskLimitBytes: 300)
        defer { cache.close() }
        cache.declareTarget(0)
        for i in 0...2 { #expect(cache.store(index: i, data: Data(count: 100))) }
        let path = cache.sessionDir.appendingPathComponent("staging-wait.tmp")
        let writer = Task {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: cache.admitStagingWrite(path: path, bytes: 100, waitForConsumer: true))
                }
            }
        }
        try await waitFor { status(cache).diskAdmissionWaiting }
        #expect(status(cache).diskAdmissionWaiting)
        #expect(!status(cache).producerParked)
        cache.declareTarget(1)
        #expect(await writer.value)
        #expect(status(cache).currentDiskBytes == 300)
        cache.discardStagingReservation(path: path)
        #expect(status(cache).stagingBytes == 0)
    }

    @Test("(#961) A short backward cache miss evicts the old forward tail")
    func shortBackwardMissMakesRoom() {
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 2, hardDiskLimitBytes: 300)
        defer { cache.close() }

        // After a short rewind, the consumer needs segment 4 again but the capped cache has only
        // kept 5...7. One-segment read-ahead can arrive before the refetched target is adopted.
        for index in 0...2 {
            cache.declareTarget(index)
            #expect(cache.store(index: index, data: Data(repeating: UInt8(index), count: 100)))
        }
        for index in 5...7 {
            cache.declareTarget(index)
            #expect(cache.store(index: index, data: Data(repeating: UInt8(index), count: 100)))
        }
        #expect(cache.totalBytes == 300)
        cache.declareTarget(4)
        cache.declareTarget(5)

        let staging = cache.sessionDir.appendingPathComponent("short-backward.tmp")
        #expect(cache.stagingWriteAdmission(path: staging, bytes: 100) == .admitted)
        #expect(cache.peek(index: 5)?.count == 100)
        #expect(cache.peek(index: 6)?.count == 100)
        #expect(cache.peek(index: 7) == nil, "the farthest old forward copy should make room first")
        #expect(status(cache).currentDiskBytes == 300)
        #expect(status(cache).stagingBytes == 100)
        #expect(!status(cache).diskAdmissionWaiting)
        #expect(!cache.storageExhausted)
    }

    @Test("Close wakes a writer parked while playback is paused")
    func closeCancelsPark() async throws {
        let cache = SegmentCache(hardDiskLimitBytes: 100)
        cache.declareTarget(0)
        #expect(cache.store(index: 0, data: Data(count: 100)))
        let path = cache.sessionDir.appendingPathComponent("staging-close.tmp")
        let writer = Task {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: cache.admitStagingWrite(path: path, bytes: 1, waitForConsumer: true))
                }
            }
        }
        try await waitFor { status(cache).diskAdmissionWaiting }
        #expect(status(cache).diskAdmissionWaiting)
        cache.close()
        #expect(await writer.value == false)
        #expect(!FileManager.default.fileExists(atPath: cache.sessionDir.path))
    }

    @Test("Reserve denial is independent of the payload cap")
    func preservesFreeSpace() {
        let cache = SegmentCache(hardDiskLimitBytes: 10_000, freeDiskReserveBytes: Int.max / 2)
        defer { cache.close() }
        cache.declareTarget(0)
        #expect(!cache.store(index: 0, data: Data(count: 100)))
        #expect(cache.totalBytes == 0)
        #expect(status(cache).rejectedDiskWrites == 1)
    }

    @Test("Available volume capacity refreshes after a write using the same URL")
    func availableVolumeCapacityRefreshesAfterWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-capacity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capacityURL = directory

        // Deterministic, incompressible data ensures APFS cannot satisfy this with a sparse or
        // compressed allocation. Keep the write modest while making the capacity change clear.
        var state: UInt64 = 0x9E3779B97F4A7C15
        let chunkSize = 1 << 20
        let chunkCount = 32
        let data = Data((0..<chunkSize).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        // The capacity is volume-wide, and in the full parallel suite other tests free space between
        // the two reads, which can swallow 32 MiB. A stale cache shows a delta of exactly 0 on every
        // attempt, so one attempt that sees the drop is enough.
        var drops: [Int64] = []
        for attempt in 0..<3 {
            let before = try #require(SegmentCache.availableVolumeBytes(at: capacityURL))
            let fileURL = directory.appendingPathComponent("capacity-probe-\(attempt).bin")
            #expect(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
            let output = try FileHandle(forWritingTo: fileURL)
            for _ in 0..<chunkCount { try output.write(contentsOf: data) }
            try output.synchronize()
            try output.close()
            let after = try #require(SegmentCache.availableVolumeBytes(at: capacityURL))
            drops.append(before - after)
            if before - after >= Int64(chunkSize * chunkCount / 2) { break }
        }
        #expect(drops.contains { $0 >= Int64(chunkSize * chunkCount / 2) },
                "capacity should reflect the file written between queries, drops \(drops)")
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func value() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    @Test("Producer cancellation releases a paused disk wait without closing the reusable cache")
    func producerCancelReleasesWait() async throws {
        let cache = SegmentCache(hardDiskLimitBytes: 100)
        defer { cache.close() }
        cache.declareTarget(0)
        #expect(cache.store(index: 0, data: Data(count: 100)))
        let stop = StopFlag()
        let path = cache.sessionDir.appendingPathComponent("staging-cancel.tmp")
        let writer = Task {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: cache.admitStagingWrite(path: path, bytes: 1, waitForConsumer: true, shouldStop: stop.value))
                }
            }
        }
        try await waitFor { status(cache).diskAdmissionWaiting }
        #expect(status(cache).diskAdmissionWaiting)
        stop.stop()
        cache.wakeWaiters()
        #expect(await writer.value == false)
        #expect(!cache.storageExhausted)
        #expect(cache.peek(index: 0)?.count == 100)
        #expect(status(cache).stagingBytes == 0)
    }

    @Test("Unadopted muxer files are removed and reservations released on cancellation")
    func cancelledMuxerRemovesStaging() throws {
        let cache = SegmentCache(hardDiskLimitBytes: 1024)
        defer { cache.close() }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64, options: .ignoreUnknownCharacters) ?? Data()), formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        var muxer: MP4SegmentMuxer? = try MP4SegmentMuxer(
            initialSegmentIndex: 0, sessionDir: cache.sessionDir,
            video: MP4SegmentMuxer.VideoConfig(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base, codecTagOverride: nil),
            audio: nil,
            discardStaging: { cache.discardStagingReservation(path: $0) }, onInitCaptured: { _ in })
        let path = try #require(muxer?.stagingURL)
        #expect(cache.admitStagingWrite(path: path, bytes: 100))
        try Data(repeating: 3, count: 100).write(to: path)
        #expect(FileManager.default.fileExists(atPath: path.path))
        muxer = nil
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(status(cache).stagingBytes == 0)
    }

    @Test("Destroying a muxer never deletes the cache file its staging was adopted into")
    func adoptedFileSurvivesMuxer() throws {
        let cache = SegmentCache(hardDiskLimitBytes: 1024)
        defer { cache.close() }
        cache.declareTarget(0)
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64, options: .ignoreUnknownCharacters) ?? Data()), formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        var muxer: MP4SegmentMuxer? = try MP4SegmentMuxer(
            initialSegmentIndex: 0, sessionDir: cache.sessionDir,
            video: MP4SegmentMuxer.VideoConfig(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base, codecTagOverride: nil),
            audio: nil, discardStaging: { cache.discardStagingReservation(path: $0) }, onInitCaptured: { _ in })
        let path = try #require(muxer?.stagingURL)
        #expect(cache.admitStagingWrite(path: path, bytes: 100))
        try Data(repeating: 9, count: 100).write(to: path)
        #expect(cache.adopt(index: 0, stagingPath: path, byteCount: 100))
        muxer = nil
        #expect(cache.peek(index: 0) == Data(repeating: 9, count: 100))
        #expect(status(cache).currentDiskBytes == 100)
    }

    @Test("Concurrent muxers cannot reserve the same free bytes twice")
    func simultaneousReservationsStayBounded() async {
        let cache = SegmentCache(hardDiskLimitBytes: 100)
        defer { cache.close() }
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for i in 0..<40 {
                group.addTask {
                    cache.admitStagingWrite(path: cache.sessionDir.appendingPathComponent("staging-concurrent-\(i).tmp"), bytes: 30)
                }
            }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        #expect(admitted == 3)
        #expect(status(cache).currentDiskBytes == 90)
    }

    @Test("A reserve works without a hard limit, including the live-session cache shape")
    func reserveWithoutHardLimit() {
        let cache = SegmentCache(freeDiskReserveBytes: 900, availableVolumeBytes: { _ in 1_000 })
        defer { cache.close() }
        let path = cache.sessionDir.appendingPathComponent("staging-reserve.tmp")
        #expect(cache.hardDiskLimitBytes == nil)
        #expect(cache.stagingWriteAdmission(path: path, bytes: 101) == .storageExhausted)
        #expect(cache.stagingWriteAdmission(path: path, bytes: 100) == .admitted)
        #expect(status(cache).stagingBytes == 100)
        #expect(status(cache).rejectedDiskWrites == 1)
    }

    @Test("An unknown capacity fails closed only when a reserve is requested")
    func unknownCapacityAndOptOut() {
        let reserved = SegmentCache(freeDiskReserveBytes: 1, availableVolumeBytes: { _ in nil })
        let legacy = SegmentCache(availableVolumeBytes: { _ in nil })
        defer { reserved.close(); legacy.close() }
        #expect(reserved.stagingWriteAdmission(path: reserved.sessionDir.appendingPathComponent("x"), bytes: 1) == .storageExhausted)
        #expect(legacy.stagingWriteAdmission(path: legacy.sessionDir.appendingPathComponent("x"), bytes: 1) == .admitted)
        #expect(!status(reserved).diskAdmissionWaiting && !status(reserved).producerParked)
    }

    @Test("Cancellation is not a capacity failure, and oversized arithmetic cannot overflow")
    func cancelledAndOversizedAdmission() {
        let cache = SegmentCache(freeDiskReserveBytes: Int.max, availableVolumeBytes: { _ in Int64.max })
        defer { cache.close() }
        let path = cache.sessionDir.appendingPathComponent("x")
        #expect(cache.stagingWriteAdmission(path: path, bytes: 1, shouldStop: { true }) == .cancelled)
        #expect(!cache.storageExhausted)
        #expect(status(cache).rejectedDiskWrites == 0)
        #expect(cache.stagingWriteAdmission(path: path, bytes: 1) == .storageExhausted)
        #expect(status(cache).stagingBytes == 0)
    }

}
