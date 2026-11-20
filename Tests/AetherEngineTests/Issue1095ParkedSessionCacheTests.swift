// AE#1095: a host that stops a title and opens it again a few minutes later used to fetch every
// segment a second time, because `stop()` deleted the session directory within a second. With
// `LoadOptions.retainsSessionCacheAfterStop` the stopped session's segments are parked, and the next
// session for the same source adopts them and starts its producer at the first one missing.
import Foundation
import Testing
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

@Suite("AE#1095: a stopped session's segments are kept for the same source", .serialized)
struct Issue1095ParkedSessionCacheTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae1095-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(condition())
    }

    private func makeSession(store: ParkedSegmentSessionStore,
                             options: LoadOptions = LoadOptions(),
                             startSeconds: Double? = nil) -> HLSVideoEngine {
        let engine = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
        engine.parkingStore = store
        engine.parkingOptions = options.normalizedForSessionParking
        engine.initialStartSeconds = startSeconds
        return engine
    }

    // MARK: - Where the producer starts

    @Test("the producer starts at the first index the parked session lacks", .timeLimit(.minutes(3)))
    func frontierIsTheFirstGap() {
        let stored: Set<Int> = [3, 4, 5, 6, 9]
        #expect(SegmentCache.parkedAdoptionFrontier(start: 4, stored: stored, folded: [], planCount: 20) == 7)
        // Not parked at the start: the producer starts there, as it would without a parked session.
        #expect(SegmentCache.parkedAdoptionFrontier(start: 2, stored: stored, folded: [], planCount: 20) == 2)
        // A hole the old pumps folded over is not a gap: no producer would ever fill it.
        #expect(SegmentCache.parkedAdoptionFrontier(start: 4, stored: stored, folded: [7, 8], planCount: 20) == 10)
        // A fully parked title still keeps one segment for its producer to cut.
        #expect(SegmentCache.parkedAdoptionFrontier(start: 0, stored: Set(0..<5), folded: [], planCount: 5) == 4)
    }

    // MARK: - What travels with the segments

    @Test("the adopted start opens a run on the axis its bytes carry, later openings stay",
          .timeLimit(.minutes(3)))
    func adoptedStartPublishesTheCarriedAxis() {
        var table = EpochAxisTable()
        table.record(EpochAxis(presented: 600, carried: 600, isRecut: false), at: 0)
        table.record(EpochAxis(presented: 605.5, carried: 604, isRecut: false), at: 9)
        var adopted = table.keeping(below: 12)
        adopted.markAdoptedStart(at: 6)
        // On a source with a 600 s origin nothing else would publish the 600 s for a fresh item.
        #expect(adopted.opening(at: 6) == EpochAxis(presented: 600, carried: 600, isRecut: false))
        #expect(adopted.opening(at: 9)?.carried == 604)
        // A start that already opens a run keeps its real backoff.
        var restartedThere = table.keeping(below: 12)
        restartedThere.markAdoptedStart(at: 9)
        #expect(restartedThere.opening(at: 9)?.presented == 605.5)
        #expect(table.keeping(below: 9).opening(at: 9) == nil)
    }

    @Test("the adopting session gets the subtitles the parked one harvested, coverage included",
          .timeLimit(.minutes(3)))
    func subtitleStoreTravels() {
        let parked = SubtitlePacketStore()
        parked.noteHarvestAnchor(.pump, at: 0)
        for second in stride(from: 1.0, through: 60, by: 3) {
            parked.append(streamIndex: 2, ptsSeconds: second, durationSeconds: 2,
                          payload: Data("line at \(second)".utf8))
            parked.noteHarvestProgress(.pump, through: second)
        }
        let fresh = SubtitlePacketStore()
        fresh.adoptContents(of: parked)
        #expect(fresh.totalRetainedBytes == parked.totalRetainedBytes)
        #expect(fresh.totalRetainedBytes > 0)
        #expect(fresh.harvestCoverageSpans == parked.harvestCoverageSpans)
        #expect(fresh.entries(streamIndex: 2, from: 10, through: 50).count
                == parked.entries(streamIndex: 2, from: 10, through: 50).count)
    }

    // MARK: - SegmentCache

    @Test("parked segments move out with their reach and come back below the frontier",
          .timeLimit(.minutes(3)))
    func cacheRoundTrip() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        let initData = Data("init".utf8)
        old.setInit(initData)
        // seg3 is a hole the pump folded over, seg6 one past where the next session will start.
        let stored = [0, 1, 2, 4, 5]
        func bytes(_ index: Int) -> Data { Data(repeating: UInt8(index), count: 100 + index) }
        for index in stored { #expect(old.store(index: index, data: bytes(index))) }
        old.noteFolded(3..<4)
        old.noteFolded(6..<7)

        let parkedDir = base.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parkedDir, withIntermediateDirectories: true)
        let parked = try #require(old.detachForParking(into: parkedDir))
        #expect(parked.files.count == stored.count)
        #expect(parked.totalBytes == stored.reduce(0) { $0 + 100 + $1 })
        #expect(parked.foldCounts == [3: 1, 6: 1])
        #expect(parked.initSegment == initData)
        #expect(old.count == 0)
        old.close()
        #expect(!FileManager.default.fileExists(atPath: old.sessionDir.path))
        #expect(parked.files.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let new = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { new.close() }
        let adopted = new.adoptParked(parked, below: 5)
        #expect(adopted.segments == 4)
        #expect(adopted.bytes == [0, 1, 2, 4].reduce(0) { $0 + 100 + $1 })
        for index in [0, 1, 2, 4] { #expect(new.peek(index: index) == bytes(index)) }
        #expect(new.peek(index: 3) == nil)
        #expect(new.peek(index: 5) == nil)
        #expect(new.highestStoredIndex == 4)
        #expect(new.foldCount(3) == 1, "a hole below the frontier stays known as one")
        #expect(new.foldCount(6) == 0, "above the frontier the new producer counts for itself")
        #expect(new.fetchInit(timeout: 0.1) == initData)
    }

    @Test("a cache with nothing a later session could use parks nothing", .timeLimit(.minutes(3)))
    func emptyCacheParksNothing() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let noInit = SegmentCache(baseDirectory: base)
        defer { noInit.close() }
        #expect(noInit.store(index: 0, data: Data(count: 10)))
        #expect(noInit.detachForParking(into: base) == nil)

        let noSegments = SegmentCache(baseDirectory: base)
        defer { noSegments.close() }
        noSegments.setInit(Data("init".utf8))
        #expect(noSegments.detachForParking(into: base) == nil)
    }

    @Test("a park that a session start overtook is dropped, not kept", .timeLimit(.minutes(3)))
    func overtakenParkIsDropped() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        func parked() throws -> ParkedSegmentSession {
            let cache = SegmentCache(baseDirectory: base)
            defer { cache.close() }
            cache.setInit(Data("init".utf8))
            #expect(cache.store(index: 0, data: Data(count: 64)))
            let dir = try #require(ParkedSegmentSession.makeDirectory(besides: cache.sessionDir))
            let segments = try #require(cache.detachForParking(into: dir.url))
            let engine = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
            engine.parkingOptions = LoadOptions()
            return ParkedSegmentSession(
                key: try #require(engine.parkingKey), plan: [], segments: segments,
                epochAxis: EpochAxisTable(), playlistShiftSeconds: 0, subtitles: SubtitlePacketStore(),
                markerFD: dir.markerFD)
        }
        let store = ParkedSegmentSessionStore()
        let stopLook = store.lookCount
        _ = store.take(matching: try parked().key)   // the immediate load after the stop
        let late = try parked()
        store.park(late, ifNoLookSince: stopLook)
        #expect(store.parkedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: late.directory.path))

        let onTime = try parked()
        store.park(onTime, ifNoLookSince: store.lookCount)
        #expect(store.parkedBytes == 64)
        store.discard(reason: "test finished")
        #expect(!FileManager.default.fileExists(atPath: onTime.directory.path))
    }

    // MARK: - Eligibility

    @Test("only VOD over a URL with the option on has a key", .timeLimit(.minutes(3)))
    func keyEligibility() {
        let url = fixtureURL("restart-witness-av.mp4")
        let off = HLSVideoEngine(url: url, dvModeAvailable: false)
        #expect(off.parkingKey == nil)

        let on = HLSVideoEngine(url: url, dvModeAvailable: false)
        on.parkingOptions = LoadOptions()
        #expect(on.parkingKey != nil)

        let live = HLSVideoEngine(url: url, dvModeAvailable: false, isLiveSession: true)
        live.parkingOptions = LoadOptions()
        #expect(live.parkingKey == nil)

        let custom = HLSVideoEngine(url: url, dvModeAvailable: false, sourceReopenableByURL: false)
        custom.parkingOptions = LoadOptions()
        #expect(custom.parkingKey == nil)
    }

    @Test("the diagnostics label does not count, a real option does", .timeLimit(.minutes(3)))
    func keyComparison() throws {
        let url = fixtureURL("restart-witness-av.mp4")
        func key(_ options: LoadOptions, delay: Double = 0) throws -> ParkedSegmentSession.Key {
            let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
            engine.parkingOptions = options.normalizedForSessionParking
            engine.audioDelaySeconds = delay
            return try #require(engine.parkingKey)
        }
        var labelled = LoadOptions()
        labelled.sourceDiagnosticsContext = .init(playbackID: UUID(), attemptID: UUID())
        #expect(try key(LoadOptions()) == key(labelled))

        var bridged = LoadOptions()
        bridged.audioBridgeMode = .lossless
        #expect(try key(LoadOptions()).firstDifference(from: key(bridged)) == "load options")
        #expect(try key(LoadOptions()).firstDifference(from: key(LoadOptions(), delay: 0.2))
                == "session output configuration")
    }

    @Test("a capped prewarm is skipped only for the same file", .timeLimit(.minutes(3)))
    func unindexedSourceMatchesByteSizeAndDuration() {
        let measured = ParkedSegmentSession.UnindexedSource(byteSize: 54_325_786, durationSeconds: 300.025)
        #expect(measured.describes(byteSize: 54_325_786, durationSeconds: 300.025))
        // Same URL, other bytes: a replaced file runs its prewarm again.
        #expect(!measured.describes(byteSize: 54_325_787, durationSeconds: 300.025))
        #expect(!measured.describes(byteSize: 54_325_786, durationSeconds: 300.0))
        // An origin that never said how large the file is proves nothing.
        #expect(!measured.describes(byteSize: nil, durationSeconds: 300.025))
    }

    // MARK: - Two real sessions

    @Test("a resume adopts what the stopped session cut and starts its producer after it",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func resumeAdoptsParkedSegments() async throws {
        let store = ParkedSegmentSessionStore()
        defer { store.discard(reason: "test finished") }

        let first = makeSession(store: store)
        _ = try first.start()
        let firstProvider = try #require(first.provider)
        let planCount = first.segmentPlan.count
        try #require(planCount >= 3, "the witness clip should cut into at least three segments")
        var cut: [Int: Data] = [:]
        for index in 0..<planCount { cut[index] = firstProvider.mediaSegment(at: index) }
        try #require(cut.count == planCount)
        let firstPlaylist = try String(contentsOf: try #require(first.mediaPlaylistURL), encoding: .utf8)
        // An MP4 carries its index, so the prewarm is never capped and the next load runs it again.
        #expect(first.unindexedSource == nil)

        first.parksSegmentsAtStop = true
        first.stop()
        try await waitFor { store.parkedBytes > 0 }

        let second = makeSession(store: store, startSeconds: 4.5)
        _ = try second.start()
        defer { second.stop() }
        // Everything was parked, so the producer is left with the last segment only.
        #expect(second.initialProducerBaseIndex == planCount - 1)
        #expect(store.parkedBytes == 0)
        let secondProvider = try #require(second.provider)
        for index in 0..<(planCount - 1) {
            #expect(second.cache?.peek(index: index) == cut[index], "seg\(index) is not the parked one")
            #expect(secondProvider.mediaSegment(at: index) == cut[index])
        }
        // The adopting session positions its demuxer on the pump thread, so this segment is only
        // there when that late seek ran before the pump's first read.
        #expect(secondProvider.mediaSegment(at: planCount - 1) != nil)
        let secondPlaylist = try String(contentsOf: try #require(second.mediaPlaylistURL), encoding: .utf8)
        #expect(secondPlaylist == firstPlaylist)
    }

    @Test("a stop the host did not ask for parks nothing",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func internalStopDoesNotPark() async throws {
        let store = ParkedSegmentSessionStore()
        defer { store.discard(reason: "test finished") }
        let session = makeSession(store: store)
        _ = try session.start()
        #expect(try #require(session.provider).mediaSegment(at: 0) != nil)
        let dir = try #require(session.cache?.sessionDir)
        session.stop()
        try await waitFor { !FileManager.default.fileExists(atPath: dir.path) }
        #expect(store.parkedBytes == 0)
    }

    @Test("a load with different options deletes the parked session instead of adopting it",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func differentOptionsDiscard() async throws {
        let store = ParkedSegmentSessionStore()
        defer { store.discard(reason: "test finished") }
        let first = makeSession(store: store)
        _ = try first.start()
        #expect(try #require(first.provider).mediaSegment(at: 0) != nil)
        first.parksSegmentsAtStop = true
        first.stop()
        try await waitFor { store.parkedBytes > 0 }

        var bridged = LoadOptions()
        bridged.audioBridgeMode = .lossless
        let second = makeSession(store: store, options: bridged)
        _ = try second.start()
        defer { second.stop() }
        #expect(store.parkedBytes == 0)
        #expect(second.initialProducerBaseIndex == 0)
    }
}
