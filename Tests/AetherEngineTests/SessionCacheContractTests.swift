import Foundation
import Testing
@testable import AetherEngine

@Suite("Session cache public contract")
struct SessionCachePublicContractTests {
    @Test("LoadOptions carries an exact caller-requested session budget")
    func loadOptionsBudget() {
        let auto = LoadOptions(sessionCacheByteBudget: 512 << 20)
        let disk = LoadOptions(sessionCacheByteBudget: 16 << 30)
        let disabled = LoadOptions(sessionCacheByteBudget: 0)
        #expect(auto.sessionCacheByteBudget == 512 << 20)
        #expect(disk.sessionCacheByteBudget == 16 << 30)
        #expect(disabled.sessionCacheByteBudget == 0)
    }

    @Test("Exact requests clamp to one quarter of free tmp capacity")
    func requestedBudgetClampsToVolume() {
        let result = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: 8 << 30,
            volumeAvailableBytes: 16 << 30,
            capRelaxed: true
        )
        #expect(result.requestedBytes == 8 << 30)
        #expect(result.volumeSafetyLimitBytes == 4 << 30)
        #expect(result.baseEffectiveBytes == 4 << 30)
    }

    @Test("Unknown capacity keeps the conservative 2 GiB safety ceiling")
    func unknownCapacityIsConservative() {
        let result = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: 16 << 30,
            volumeAvailableBytes: nil,
            capRelaxed: true
        )
        #expect(result.requestedBytes == 16 << 30)
        #expect(result.baseEffectiveBytes == 2 << 30)
    }

    @Test("Zero expresses window-only caching")
    func zeroBudgetIsWindowOnly() {
        let result = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: 0,
            volumeAvailableBytes: 100 << 30,
            capRelaxed: false
        )
        #expect(result.baseEffectiveBytes == 0)
        #expect(result.enforcedBytes == 1)
    }

    @Test("An explicit request never reaches the cache as the unbounded 0")
    func explicitRequestStaysBounded() {
        let full = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: 512 << 20, volumeAvailableBytes: 3, capRelaxed: true)
        #expect(full.baseEffectiveBytes == 0)
        #expect(full.enforcedBytes == 1)
        let automatic = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: nil, volumeAvailableBytes: 100 << 30)
        #expect(automatic.enforcedBytes == automatic.baseEffectiveBytes)
        #expect(PrefetchDiskBudget.shouldPark(
            forwardBytes: 10, budgetBytes: full.enforcedBytes,
            head: PrefetchDiskBudget.minAheadSegments, consumerTarget: 0))
    }

    @Test("Native remote HLS reports unsupported rather than zero-byte support")
    func nativeRemoteHLSIsUnsupported() {
        let status = SessionCacheStatus.nativeRemoteHLS(requestedBudgetBytes: 512 << 20)
        #expect(status.route == .nativeRemoteHLS)
        #expect(status.capability == .unsupported)
        #expect(status.requestedBudgetBytes == 512 << 20)
        #expect(status.currentResidentBytes == 0)
    }
}

@Suite("Session cache lifecycle and pressure contract", .offCooperativePool, .timeLimit(.minutes(3)))
struct SessionCacheLifecycleContractTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-cache-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Runtime hard window raises effective bytes instead of starving playback")
    func hardWindowRaisesEffectiveBudget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(
            forwardWindow: 1_000,
            backwardWindow: 20,
            retentionBudgetBytes: 50,
            baseDirectory: root,
            sessionID: "current"
        )
        defer { _ = cache.close(reason: .sessionStopped) }
        cache.declareTarget(0)
        for index in 0...10 {
            #expect(cache.store(index: index, data: Data(repeating: 1, count: 10)))
        }
        let status = cache.status(
            route: .loopbackFMP4,
            requestedBudgetBytes: 50,
            baseEffectiveBudgetBytes: 50,
            volumeSafetyLimitBytes: 1_000
        )
        #expect(status.playbackSafeFloorBytes == 110)
        #expect(status.effectiveBudgetBytes == 110)
        #expect(status.hardWindowFloorExceeded)
    }

    @Test("Producer park is observable and releases when the consumer advances")
    func producerParkStatus() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(
            forwardWindow: 1_000,
            backwardWindow: 2,
            retentionBudgetBytes: 50,
            baseDirectory: root,
            sessionID: "current"
        )
        defer { _ = cache.close(reason: .sessionStopped) }
        cache.declareTarget(0)
        for index in 0...10 { _ = cache.store(index: index, data: Data(repeating: 1, count: 10)) }
        #expect(cache.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 50, timeout: 0.01) == false)
        #expect(cache.producerParked)
        cache.declareTarget(9)
        #expect(cache.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 50, timeout: 0.01))
        #expect(cache.producerParked == false)
    }

    @Test("Close deletes the session directory and records its reason")
    func closeDeletesSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(baseDirectory: root, sessionID: "current")
        #expect(cache.store(index: 0, data: Data(repeating: 1, count: 32)))
        let result = cache.close(reason: .sourceChanged)
        #expect(result == .succeeded)
        #expect(FileManager.default.fileExists(atPath: cache.sessionDir.path) == false)
        #expect(cache.lastCleanupReason == .sourceChanged)
    }

    @Test("A failed session directory makes writes fail closed without false accounting")
    func writeFailureFailsClosed() throws {
        let rootFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-cache-file-\(UUID().uuidString)")
        try Data([1]).write(to: rootFile)
        defer { try? FileManager.default.removeItem(at: rootFile) }
        let cache = SegmentCache(baseDirectory: rootFile, sessionID: "impossible")
        #expect(cache.store(index: 0, data: Data(repeating: 1, count: 32)) == false)
        #expect(cache.totalBytes == 0)
        #expect(cache.lastFailure == .writeFailed)
        _ = cache.close(reason: .loadFailed)
    }

    @Test("A failed replacement preserves the previous generation and its accounting")
    func adoptFailurePreservesResidentGeneration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(baseDirectory: root, sessionID: "current")
        defer { _ = cache.close(reason: .sessionStopped) }
        #expect(cache.store(index: 0, data: Data(repeating: 1, count: 32)))
        let resident = try #require(cache.peek(index: 0))
        let missing = root.appendingPathComponent("missing-staging.m4s")
        #expect(cache.adopt(index: 0, stagingPath: missing, byteCount: 64) == false)
        #expect(cache.totalBytes == 32)
        #expect(cache.peek(index: 0) == resident)
        #expect(resident == Data(repeating: 1, count: 32))
        #expect(cache.lastFailure == .adoptFailed)
    }

    @Test("Bounded stale sweep removes only expired siblings and preserves current and fresh")
    func boundedStaleSweep() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let current = root.appendingPathComponent("current", isDirectory: true)
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        var stale: [URL] = []
        for index in 0..<5 {
            let url = root.appendingPathComponent("stale-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.creationDate: now.addingTimeInterval(-7_200 - Double(index))],
                ofItemAtPath: url.path
            )
            stale.append(url)
        }

        let first = SegmentCache.sweepStaleSessionDirs(
            baseDir: root,
            currentSession: "current",
            now: now,
            maxEntries: 7,
            maxRemovals: 2
        )
        #expect(first.inspectedCount <= 7)
        #expect(first.removedCount == 2)
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(stale.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 3)
    }
}

@Suite("Session budgets preserve automatic and multi-session policy")
struct SessionCacheBudgetCompatibilityTests {
    @Test(arguments: [Int64(-1), 0, 1024, 16 << 30], [false, true])
    func automaticUnchanged(available: Int64, relaxed: Bool) {
        let expected = relaxed ? max(0, Int(available / 4)) : min(2 << 30, max(0, Int(available / 4)))
        #expect(HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: nil,
            volumeAvailableBytes: available, capRelaxed: relaxed).baseEffectiveBytes == expected)
    }

    @Test func negativeAndUnknown() {
        #expect(HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: -1,
            volumeAvailableBytes: 100).baseEffectiveBytes == 0)
        #expect(HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: nil,
            volumeAvailableBytes: nil, capRelaxed: true).baseEffectiveBytes == 2 << 30)
    }

    @Test func sharedClaimsLeaveHeadroomForLaterSessions() {
        let ledger = RetentionClaims()
        let first = ledger.claim(volumeAvailableBytes: 1600) {
            HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: 1000, volumeAvailableBytes: $0).baseEffectiveBytes
        }
        let second = ledger.claim(volumeAvailableBytes: 1600) {
            HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: 1000, volumeAvailableBytes: $0).baseEffectiveBytes
        }
        #expect(first.bytes == 400)
        #expect(second.bytes == 300)
        first.release()
        second.release()
        let shrunk = ledger.claim(volumeAvailableBytes: 100) {
            HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: 1000, volumeAvailableBytes: $0).baseEffectiveBytes
        }
        #expect(shrunk.bytes == 25)
        shrunk.release()
    }
}

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct SessionCachePublicationTests {
    @Test func oldCallbackCannotReplaceNewSessionOrStoppedState() throws {
        let engine = try AetherEngine()
        let old = engine.sessionCacheStatusToken
        engine.sessionCacheStatusToken &+= 1
        let expected = SessionCacheStatus.nativeRemoteHLS(requestedBudgetBytes: 123)
        engine.diagnostics.sessionCacheStatus = expected
        engine.acceptSessionCacheStatus(.inactive, token: old)
        #expect(engine.diagnostics.sessionCacheStatus == expected)
        // A queued startup snapshot cannot resurrect a cache after stop detached the session.
        engine.acceptSessionCacheStatus(.inactive, token: engine.sessionCacheStatusToken)
        #expect(engine.diagnostics.sessionCacheStatus == expected)
        engine.stop()
        #expect(engine.diagnostics.sessionCacheStatus == .inactive)
    }

    @Test func actualLoadStopReportsDeletionAndNewLoadRejectsOldCleanup() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        func source() throws -> MediaSource {
            .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        }
        _ = try await engine.load(source: source(), options: LoadOptions(sessionCacheByteBudget: 0))
        let old = try #require(engine.nativeVideoSession)
        let directory = try #require(old.cache).sessionDir
        let oldToken = engine.sessionCacheStatusToken
        await engine.refreshSessionCacheStatus()
        #expect(engine.diagnostics.sessionCacheStatus.route == .loopbackFMP4)
        #expect(engine.diagnostics.sessionCacheStatus.baseEffectiveBudgetBytes == 0)
        engine.stop()
        try await waitFor { engine.diagnostics.sessionCacheStatus.cleanupResult != .notRun }
        let cleaned = engine.diagnostics.sessionCacheStatus
        #expect(cleaned.cleanupReason == .sessionStopped)
        #expect(cleaned.cleanupResult == .succeeded)
        #expect(cleaned.capability == .inactive)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        _ = try await engine.load(source: source(), options: LoadOptions(sessionCacheByteBudget: 1024))
        await engine.refreshSessionCacheStatus()
        let current = engine.diagnostics.sessionCacheStatus
        engine.acceptSessionCacheStatus(cleaned, token: oldToken)
        #expect(engine.diagnostics.sessionCacheStatus == current)
        #expect(current.requestedBudgetBytes == 1024)
    }
}

extension SessionCacheLifecycleContractTests {
    @Test func liveBudgetCapabilityAndClosedStateAreExplicit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SegmentCache(baseDirectory: root)
        let session = HLSVideoEngine(url: URL(string: "https://example.invalid/live")!,
                                    isLiveSession: true, sessionCacheByteBudget: 123)
        session.cache = cache
        #expect(session.sessionCacheStatus().capability == .unsupported)
        _ = cache.close(reason: .sessionStopped)
        #expect(session.sessionCacheStatus().capability == .inactive)
    }

    @Test func cleanupFailureDoesNotClaimSuccessfulDeletion() throws {
        let root = try makeRoot()
        let cache = SegmentCache(baseDirectory: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(cache.close(reason: .loadFailed) == .failed)
        let status = cache.status(route: .loopbackFMP4, requestedBudgetBytes: nil,
                                  baseEffectiveBudgetBytes: 0, volumeSafetyLimitBytes: nil)
        #expect(status.cleanupReason == .loadFailed)
        #expect(status.lastFailure == .cleanupFailed)
        #expect(FileManager.default.fileExists(atPath: cache.sessionDir.path))
    }

    @Test func sweepEnumerationFailureIsReported() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let result = SegmentCache.sweepStaleSessionDirs(baseDir: missing, currentSession: "unused")
        #expect(result.failureCount > 0)
        #expect(result.removedCount == 0)
    }
}

extension SessionCacheBudgetCompatibilityTests {
    @Test(arguments: [Int64(0), 1024, 16 << 30], [false, true])
    func softwareAutomaticIsUnchanged(available: Int64, relaxed: Bool) {
        #expect(SoftwarePlaybackHost.packetCacheBudgetBytes(requestedBytes: nil,
            availableBytes: available, capRelaxed: relaxed) ==
            HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: available, capRelaxed: relaxed))
    }

    @Test func softwareWindowOnlyStillRespectsVolumeSafety() {
        #expect(SoftwarePlaybackHost.packetCacheBudgetBytes(requestedBytes: 0,
            availableBytes: 16 << 30, capRelaxed: true) == 32 << 20)
        #expect(SoftwarePlaybackHost.packetCacheBudgetBytes(requestedBytes: 0,
            availableBytes: 1024, capRelaxed: true) == 256)
        #expect(SoftwarePlaybackHost.packetCacheBudgetBytes(requestedBytes: 100,
            availableBytes: 1024, capRelaxed: true) == 100)
        #expect(SoftwarePlaybackHost.packetCacheBudgetBytes(requestedBytes: Int.max,
            availableBytes: nil, capRelaxed: true) == 2 << 30)
    }
}

extension SessionCachePublicContractTests {
    @Test func stopRetainsZeroArgumentCallbackCompatibility() {
        let session = HLSVideoEngine(url: URL(string: "https://example.invalid/unused")!)
        let stop: () -> Void = session.stop
        stop()
        #expect(session.sessionCacheStatus().capability == .inactive)
    }
}
