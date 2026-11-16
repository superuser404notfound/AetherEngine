// Tests/AetherEngineTests/IFrameRenditionTests.swift
import Foundation
import Testing
@testable import AetherEngine

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _reads: [Int64] = []
    private var _closed = 0, _interrupted = 0, _waits = 0
    var failing: Set<Int64> = []
    var readsAllowed = true
    /// Runs inside a read, before it answers. Lets a test park a read or stop the rendition under it.
    var duringRead: (@Sendable (IFrameRendition.Entry) -> Void)?
    func read(_ e: IFrameRendition.Entry) -> Data? {
        lock.lock(); _reads.append(e.startPts); lock.unlock()
        duringRead?(e)
        return failing.contains(e.startPts) ? nil : Data("key\(e.startPts)".utf8)
    }
    func noteClose() { lock.lock(); _closed += 1; lock.unlock() }
    /// Signalled when shutdown has set its flag and is asking the reader to abort.
    let interruptSeen = DispatchSemaphore(value: 0)
    func noteInterrupt() { lock.lock(); _interrupted += 1; lock.unlock(); interruptSeen.signal() }
    func noteWait() { lock.lock(); _waits += 1; lock.unlock() }
    var reads: [Int64] { lock.lock(); defer { lock.unlock() }; return _reads }
    var closed: Int { lock.lock(); defer { lock.unlock() }; return _closed }
    var interrupted: Int { lock.lock(); defer { lock.unlock() }; return _interrupted }
    var waits: Int { lock.lock(); defer { lock.unlock() }; return _waits }
}

@Suite(.offCooperativePool)
struct IFrameRenditionTests {
    private func make(_ rec: Recorder, count: Int = 5) -> (IFrameRendition, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iframe-rendition-\(UUID().uuidString)", isDirectory: true)
        let entries = (0..<count).map {
            IFrameRendition.Entry(startPts: Int64($0) * 1000, startSeconds: Double($0) * 4, durationSeconds: 4)
        }
        let rendition = IFrameRendition(
            entries: entries,
            cache: IFramePayloadCache(directory: dir, byteLimit: 1 << 20),
            readPayload: rec.read,
            buildFragment: { payload, index, entry in
                // The fragment names the payload it was built from and the time it was stamped with.
                IFrameFragmentBuilder.Output(
                    initSegment: Data("init".utf8),
                    fragment: payload + Data("@\(index):\(entry.startSeconds)".utf8))
            },
            waitForLink: { _ in rec.noteWait() },
            sourceReadsAllowed: { rec.readsAllowed },
            interruptReads: rec.noteInterrupt,
            closeReader: rec.noteClose)
        return (rendition, dir)
    }

    @Test("a fragment is the entry's own keyframe stamped with the entry's time")
    func ownKeyframe() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.fragment(at: 2) == Data("key2000@2:8.0".utf8))
    }

    @Test("a prefetched keyframe answers the later request without another read")
    func prefetchFeedsRequest() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.prefetch(at: 2, buildsFragment: false) == Data("key2000".utf8))
        #expect(r.fragment(at: 2) == Data("key2000@2:8.0".utf8))
        #expect(rec.reads == [2000])
    }

    @Test("a prefetch builds the fragment only when asked, and never stands a neighbour in")
    func prefetchBuildsOnRequest() {
        let rec = Recorder()
        rec.failing = [3000]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iframe-prefetch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let builds = Recorder()
        let entries = (0..<5).map {
            IFrameRendition.Entry(startPts: Int64($0) * 1000, startSeconds: Double($0) * 4, durationSeconds: 4)
        }
        let r = IFrameRendition(
            entries: entries, cache: IFramePayloadCache(directory: dir, byteLimit: 1 << 20),
            readPayload: rec.read,
            buildFragment: { payload, _, entry in
                _ = builds.read(entry)
                return IFrameFragmentBuilder.Output(initSegment: Data("init".utf8), fragment: payload)
            })
        defer { r.shutdown() }
        _ = r.prefetch(at: 1, buildsFragment: false)
        #expect(builds.reads.isEmpty)
        _ = r.prefetch(at: 2, buildsFragment: true)
        #expect(builds.reads == [2000])
        #expect(r.prefetch(at: 3, buildsFragment: true) == nil)
        #expect(builds.reads == [2000])
        #expect(r.prefetch(at: 9, buildsFragment: true) == nil)
    }

    @Test("a second request for the same index reads the source once")
    func cachesPayload() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 3)
        _ = r.fragment(at: 3)
        #expect(rec.reads == [3000])
    }

    @Test("the init arrives without any fragment having been requested, by building entry 0")
    func initBuildsFirstEntry() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.initSegment() == Data("init".utf8))
        #expect(rec.reads == [0])
        #expect(r.initSegment() == Data("init".utf8))
        #expect(rec.reads == [0])
    }

    @Test("a failed read is answered with the nearest cached keyframe, stamped as the asked index")
    func substitutesNearestPayloadWhenReadFails() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 1)
        rec.failing = [3000]
        #expect(r.fragment(at: 3) == Data("key1000@3:12.0".utf8))
    }

    @Test("a failed read with nothing cached is nil")
    func nothingToSubstitute() {
        let rec = Recorder()
        rec.failing = [2000]
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.fragment(at: 2) == nil)
    }

    @Test("an index outside the plan is nil and reads nothing", arguments: [-1, 5, 9999])
    func outOfRangeIndexIsNil(index: Int) {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.fragment(at: index) == nil)
        #expect(rec.reads.isEmpty)
    }

    @Test("the link wait runs before a source read and not before a cache hit")
    func waitsOnlyBeforeReads() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 0)
        _ = r.fragment(at: 0)
        #expect(rec.waits == 1)
    }

    @Test("after shutdown every call is nil, the reader is interrupted and closed exactly once")
    func answersNilAfterShutdown() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 0)
        r.shutdown()
        r.shutdown()
        #expect(r.fragment(at: 1) == nil)
        #expect(r.initSegment() == nil)
        #expect(rec.reads == [0])
        #expect(rec.interrupted == 1)
        #expect(rec.closed == 1)
    }

    @Test("concurrent requests are served one at a time and all complete")
    func concurrentRequests() async {
        let rec = Recorder()
        let (r, dir) = make(rec, count: 40); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<40 { group.addTask { r.fragment(at: i) != nil } }
            for await ok in group { #expect(ok) }
        }
        #expect(Set(rec.reads).count == 40)
    }

    @Test("a read that teardown interrupted is not answered with a neighbour")
    func noSubstitutionAfterAnInterruptedRead() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 1)
        rec.failing = [3000]
        let stopped = DispatchSemaphore(value: 0)
        rec.duringRead = { entry in
            guard entry.startPts == 3000 else { return }
            // Teardown arrives while this read is in flight; the read then fails, as an aborted one does.
            // Its own thread and a signal instead of a sleep: a loaded runner starves the global pool.
            Thread.detachNewThread { r.shutdown(); stopped.signal() }
            rec.interruptSeen.wait()
        }
        #expect(r.fragment(at: 3) == nil)
        stopped.wait()
    }

    @Test("a second shutdown waits for the request the first one is still draining")
    func aSecondShutdownWaitsForTheRequestInFlight() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { try? FileManager.default.removeItem(at: dir) }
        let parked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        rec.duringRead = { _ in parked.signal(); release.wait() }
        let requestDone = DispatchSemaphore(value: 0), firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = r.fragment(at: 0); requestDone.signal() }
        parked.wait()
        Thread.detachNewThread { r.shutdown(); firstDone.signal() }
        Thread.sleep(forTimeInterval: 0.1)
        Thread.detachNewThread { r.shutdown(); secondDone.signal() }
        // The session frees the codec parameters right after its own shutdown() returns, so that
        // call must not come back while a build can still be running.
        #expect(secondDone.wait(timeout: .now() + 0.4) == .timedOut)
        release.signal()
        requestDone.wait(); firstDone.wait()
        #expect(secondDone.wait(timeout: .now() + 120) == .success)
    }

    @Test("while source reads are held, a request is answered from the cache or not at all")
    func servesFromCacheOnlyWhileSourceReadsAreHeld() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        rec.readsAllowed = false
        #expect(r.fragment(at: 2) == nil)
        #expect(rec.reads.isEmpty)
        rec.readsAllowed = true
        _ = r.fragment(at: 1)
        rec.readsAllowed = false
        #expect(r.fragment(at: 1) == Data("key1000@1:4.0".utf8))
        #expect(r.fragment(at: 3) == Data("key1000@3:12.0".utf8))
        #expect(rec.reads == [1000])
    }

    @Test("a preview keyframe is the entry's own payload, read once, and never a neighbour's")
    func previewKeyframeNoStandIn() {
        let rec = Recorder()
        rec.failing = [3000]
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.keyframePayload(at: 2) == Data("key2000".utf8))
        #expect(r.keyframePayload(at: 2) == Data("key2000".utf8))
        #expect(r.keyframePayload(at: 3) == nil)
        #expect(rec.reads == [2000, 3000])
    }

    @Test("a stale preview request reads nothing but still answers from the cache")
    func previewKeyframeStale() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.keyframePayload(at: 1) == Data("key1000".utf8))
        #expect(r.keyframePayload(at: 4, isStale: { true }) == nil)
        #expect(r.keyframePayload(at: 1, isStale: { true }) == Data("key1000".utf8))
        #expect(rec.reads == [1000])
    }

    @Test("preview keyframes respect held source reads, the link wait and shutdown")
    func previewKeyframeGates() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { try? FileManager.default.removeItem(at: dir) }
        rec.readsAllowed = false
        #expect(r.keyframePayload(at: 0) == nil)
        #expect(rec.reads.isEmpty)
        rec.readsAllowed = true
        #expect(r.keyframePayload(at: 0) != nil)
        #expect(rec.waits == 1)
        r.shutdown()
        #expect(r.keyframePayload(at: 0) == nil)
        #expect(r.keyframePayload(at: 7) == nil)
    }

    @Test("the failure line is written once per window and counts what it swallowed")
    func logThrottle() {
        var throttle = IFrameLogThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(throttle.shouldEmit(now: t0) == 0)
        #expect(throttle.shouldEmit(now: t0.addingTimeInterval(1)) == nil)
        #expect(throttle.shouldEmit(now: t0.addingTimeInterval(4.9)) == nil)
        #expect(throttle.shouldEmit(now: t0.addingTimeInterval(5)) == 2)
        #expect(throttle.shouldEmit(now: t0.addingTimeInterval(6)) == nil)
        #expect(throttle.shouldEmit(now: t0.addingTimeInterval(11)) == 1)
    }
}
