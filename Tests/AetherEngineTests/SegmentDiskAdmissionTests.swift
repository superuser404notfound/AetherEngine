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
        let writer = Task.detached {
            cache.admitStagingWrite(path: path, bytes: 100, waitForConsumer: true)
        }
        try await waitFor { status(cache).producerParked }
        #expect(status(cache).producerParked)
        cache.declareTarget(1)
        #expect(await writer.value)
        #expect(status(cache).currentDiskBytes == 300)
        cache.discardStagingReservation(path: path)
        #expect(status(cache).stagingBytes == 0)
    }

    @Test("Close wakes a writer parked while playback is paused")
    func closeCancelsPark() async throws {
        let cache = SegmentCache(hardDiskLimitBytes: 100)
        cache.declareTarget(0)
        #expect(cache.store(index: 0, data: Data(count: 100)))
        let path = cache.sessionDir.appendingPathComponent("staging-close.tmp")
        let writer = Task.detached {
            cache.admitStagingWrite(path: path, bytes: 1, waitForConsumer: true)
        }
        try await waitFor { status(cache).producerParked }
        #expect(status(cache).producerParked)
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
        let writer = Task.detached {
            cache.admitStagingWrite(path: path, bytes: 1, waitForConsumer: true, shouldStop: stop.value)
        }
        try await waitFor { status(cache).producerParked }
        #expect(status(cache).producerParked)
        stop.stop()
        cache.wakeWaiters()
        #expect(await writer.value == false)
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

}
