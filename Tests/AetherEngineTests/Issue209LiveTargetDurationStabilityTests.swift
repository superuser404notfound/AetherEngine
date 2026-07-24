import XCTest
@testable import AetherEngine

private final class Issue209Cadence: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double?

    var value: Double? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

private final class Issue209WaitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func store(_ value: Bool) {
        lock.lock()
        _value = value
        lock.unlock()
    }
}

final class Issue209LiveTargetDurationStabilityTests: XCTestCase {
    private func makeProvider(
        cadence: Issue209Cadence
    ) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let policy = LiveCadencePolicy(
            observe: { cadence.value },
            cutTargetSeconds: 0.5,
            disciplineObservationSeconds: 12,
            initialFloorSeconds: nil,
            clock: { 0 }
        )
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.64002A,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 50,
            hdcpLevel: nil,
            sourceBitrate: 6_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: 0.5,
                dvrWindowSeconds: nil
            ),
            liveCadencePolicy: policy
        )
        return (provider, cache)
    }

    private func targetDuration(_ playlist: String) -> Int? {
        playlist.split(separator: "\n")
            .first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            .flatMap { Int($0.dropFirst("#EXT-X-TARGETDURATION:".count)) }
    }

    private func holdBack(_ playlist: String) -> String? {
        guard let line = playlist.split(separator: "\n")
            .first(where: { $0.hasPrefix("#EXT-X-SERVER-CONTROL:") }),
              let marker = line.range(of: "HOLD-BACK=") else {
            return nil
        }
        return line[marker.lowerBound...].split(separator: ",").first.map(String.init)
    }

    func testBuilderSealsTargetDurationAcrossCadenceAndSegmentGrowth() {
        let cadence = Issue209Cadence()
        cadence.value = 0.9
        let (provider, cache) = makeProvider(cadence: cadence)
        defer { cache.close() }

        for index in 0..<4 {
            provider.appendLiveSegment(
                index: index,
                startSeconds: Double(index) * 0.9,
                durationSeconds: 0.9
            )
        }
        let first = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        XCTAssertEqual(targetDuration(first), 1)
        XCTAssertEqual(holdBack(first), "HOLD-BACK=3.000")

        cadence.value = 1.8
        provider.appendLiveSegment(index: 4, startSeconds: 3.6, durationSeconds: 0.9)
        let second = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        XCTAssertEqual(targetDuration(second), 1)
        XCTAssertEqual(holdBack(second), "HOLD-BACK=3.000")
    }

    func testBuilderKeepsSealWhenVisibleMaximumGrows() {
        let cadence = Issue209Cadence()
        cadence.value = 0.9
        let (provider, cache) = makeProvider(cadence: cadence)
        defer { cache.close() }

        for index in 0..<4 {
            provider.appendLiveSegment(
                index: index,
                startSeconds: Double(index) * 0.9,
                durationSeconds: 0.9
            )
        }
        let first = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        XCTAssertEqual(targetDuration(first), 1)

        provider.appendLiveSegment(index: 4, startSeconds: 3.6, durationSeconds: 1.2)
        let second = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        XCTAssertEqual(targetDuration(second), 1)
        XCTAssertEqual(holdBack(second), "HOLD-BACK=3.000")
    }

    func testSealReportsOnlyFirstUpwardDrift() {
        var seal = LiveTargetDurationSeal()
        XCTAssertEqual(seal.resolve(candidate: 1).value, 1)

        let firstDrift = seal.resolve(candidate: 2)
        XCTAssertEqual(firstDrift.value, 1)
        XCTAssertTrue(firstDrift.shouldLogDrift)

        let repeatedDrift = seal.resolve(candidate: 3)
        XCTAssertEqual(repeatedDrift.value, 1)
        XCTAssertFalse(repeatedDrift.shouldLogDrift)
    }

    func testStartupGateRereadsCadenceFloorAfterEveryWake() {
        let cadence = Issue209Cadence()
        cadence.value = 0.9
        let (provider, cache) = makeProvider(cadence: cadence)
        defer { cache.close() }

        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.9)
        provider.appendLiveSegment(index: 1, startSeconds: 0.9, durationSeconds: 0.9)

        let result = Issue209WaitResult()
        let finished = expectation(description: "startup waiter finishes after cancellation")
        DispatchQueue.global().async {
            result.store(provider.waitForFirstLiveSegment(timeout: 2))
            finished.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.1)
        cadence.value = 2.2
        provider.appendLiveSegment(index: 2, startSeconds: 1.8, durationSeconds: 0.9)
        provider.appendLiveSegment(index: 3, startSeconds: 2.7, durationSeconds: 0.9)

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNil(
            result.value,
            "3.6s must not satisfy the refreshed TD=3, 9s holdback"
        )

        provider.cancelWaiters()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(result.value, false)
    }

    func testValueSealedByGateIsUsedByFirstPlaylistBuild() {
        let cadence = Issue209Cadence()
        cadence.value = 0.9
        let (provider, cache) = makeProvider(cadence: cadence)
        defer { cache.close() }

        for index in 0..<4 {
            provider.appendLiveSegment(
                index: index,
                startSeconds: Double(index) * 0.9,
                durationSeconds: 0.9
            )
        }
        XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 0.1))

        cadence.value = 1.8
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        XCTAssertEqual(targetDuration(playlist), 1)
        XCTAssertEqual(holdBack(playlist), "HOLD-BACK=3.000")
    }
}
