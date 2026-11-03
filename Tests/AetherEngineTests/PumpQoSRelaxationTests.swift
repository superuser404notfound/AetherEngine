import Foundation
import Testing
@testable import AetherEngine

/// AE#286: the pump may only drop to the efficiency QoS while nothing is waiting on it. The local
/// server answers segment requests from a `.userInitiated` work queue and parks that thread in
/// `cache.fetch` on a miss, a dependency dispatch cannot see, so every window where the consumer can
/// be blocked has to keep the pump at the responsive class.
@Suite("Pump QoS relaxation (#286)")
struct PumpQoSRelaxationTests {

    private func mayRelax(started: Bool = true, target: Int, head: Int, lead: Int = 4) -> Bool {
        HLSSegmentProducer.pumpMayRelax(hasStartedRendering: started, targetIndex: target,
                                        epochHighestStored: head, relaxedLeadSegments: lead)
    }

    @Test("A comfortable lead relaxes")
    func comfortableLeadRelaxes() {
        #expect(mayRelax(target: 3, head: 7))
        #expect(mayRelax(target: 0, head: 9))
    }

    @Test("Cold start never relaxes, whichever guard catches it")
    func coldStartStaysResponsive() {
        // Consumer has not fetched anything: the sentinel -1 makes the lead look large.
        #expect(!mayRelax(target: -1, head: 9))
        // Consumer has fetched but AVPlayer is still filling its startup buffer.
        #expect(!mayRelax(started: false, target: 0, head: 9))
    }

    @Test("A consumer sitting on the production head never relaxes")
    func consumerAtHeadStaysResponsive() {
        #expect(!mayRelax(target: 40, head: 40))
        #expect(!mayRelax(target: 40, head: 42))
    }

    @Test("A restarted pump has produced nothing, whatever the cache's high-water says")
    func freshEpochStaysResponsive() {
        // The head passed in is per-epoch. A seek restart at idx=127 with the previous epoch stored
        // through 135 must not read as a lead of 7: this pump has written nothing yet.
        #expect(!mayRelax(target: 128, head: Int.min))
        #expect(!mayRelax(target: 0, head: -1))
    }

    @Test("The lead threshold is content time, not a segment count")
    func leadThresholdIsContentTime() {
        // 16 s of content, floored at 2 segments so a long-segment source cannot relax on one segment.
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 4.0) == 4)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 6.0) == 3)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 2.0) == 8)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 10.0) == 2)
        // Degenerate durations must not produce a zero or negative threshold.
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 0) == 16)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: -1) == 16)
    }

    private final class ObservedQoS: @unchecked Sendable {
        private let lock = NSLock()
        private var _parked: qos_class_t?
        private var _finished: qos_class_t?
        func parked(_ qos: qos_class_t) { lock.withLock { _parked = qos } }
        func finished(_ qos: qos_class_t) { lock.withLock { _finished = qos } }
        var parked: qos_class_t? { lock.withLock { _parked } }
        var finished: qos_class_t? { lock.withLock { _finished } }
    }

    /// A relaxed pump is still waited on when it ends: a seek's restart stops it and blocks in
    /// `waitForFinish` on the local server's `.userInitiated` queue. A condition donates no priority
    /// to the thread it waits for, so the pump tore down and broadcast its finish at `.utility`, which
    /// Xcode's Thread Performance Checker reports as a user-initiated thread waiting on a utility one.
    @Test("A relaxed pump that is stopped and waited on unwinds at the responsive class",
          .timeLimit(.minutes(3)))
    func relaxedPumpUnwindsResponsive() async throws {
        let data = try #require(Data(base64Encoded: Issue234SideReaderSeekAnchorTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))

        // The fixture has a keyframe every second, so one segment per second. An 8 s target puts the
        // relaxed lead at its 2-segment floor, and a forward window of 4 parks the pump at segment 5
        // while the consumer sits on segment 0.
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        defer { cache.close() }
        cache.declareTarget(0)
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: videoIndex,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                         timeBase: stream.pointee.time_base, codecTagOverride: nil),
            cache: cache, targetSegmentDurationSeconds: 8, videoFallbackDurationPts: 200,
            desiredFirstVideoTfdtPts: 0, segmentBoundaries: (0..<15).map { Int64($0) * 1000 },
            bufferAheadSegments: 4)
        let observed = ObservedQoS()
        producer.hasStartedRenderingProvider = { true }
        // A paused consumer, so the park holds without the wedge breaker ending the pump on its own.
        // Asked on the pump thread once a second while it is parked.
        producer.wantsToPlayProvider = { observed.parked(qos_class_self()); return false }
        // Runs on the pump thread right after the finish broadcast.
        producer.onPumpFinished = { _ in observed.finished(qos_class_self()) }
        producer.start()

        try await waitFor { observed.parked == QOS_CLASS_UTILITY }

        producer.stop()
        await withCheckedContinuation { (exited: CheckedContinuation<Void, Never>) in
            let waiter = Thread {
                while !producer.waitForFinish(timeout: 1) {}
                exited.resume()
            }
            waiter.qualityOfService = .userInitiated
            waiter.start()
        }
        try await waitFor { observed.finished != nil }
        #expect(observed.finished == QOS_CLASS_USER_INITIATED,
                "the pump unwound at \(QoSClass.name(observed.finished ?? QOS_CLASS_UNSPECIFIED))")
    }
}
