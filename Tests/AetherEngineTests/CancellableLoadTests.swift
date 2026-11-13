import Combine
import Foundation
import Testing
@testable import AetherEngine

/// Sodalite#173: a host that cancels the Task awaiting `load()` (a zap past an unreachable channel)
/// waited out the whole connect budget, 19 s on the reporter's box, and every zap queued behind it.
/// Cancelling that Task now ends the load at once, the way a `stop()` would have.
@Suite("Cancelling the task that awaits load() ends the load", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct CancellableLoadTests {

    /// Parks its first read until the engine closes or cancels it, or until `fallback` runs out,
    /// which only an engine that never reaches it lets happen. The fallback is far above the wait:
    /// on a loaded CI runner the main actor took over 10 s to get from "entered" to the cancel, and
    /// the read gave up first, so the load failed before it was cancelled.
    final class ParkedReader: IOReader, @unchecked Sendable {
        private let condition = NSCondition()
        private let fallback: TimeInterval
        private var arrivals = 0
        private var releasedByEngine = false

        static let defaultFallback: TimeInterval = 120

        init(fallback: TimeInterval = defaultFallback) { self.fallback = fallback }

        var entered: Bool { condition.withLock { arrivals > 0 } }
        var wasReleasedByEngine: Bool { condition.withLock { releasedByEngine } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            condition.lock()
            defer { condition.unlock() }
            arrivals += 1
            let deadline = Date().addingTimeInterval(fallback)
            while !releasedByEngine, condition.wait(until: deadline) {}
            return -1
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() { condition.withLock { releasedByEngine = true; condition.broadcast() } }
        func cancel() { close() }
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    enum Outcome: Equatable { case returned, cancelled, failed(String) }

    final class OutcomeBox {
        var outcome: Outcome?
    }

    private static func start(_ engine: AetherEngine, _ source: MediaSource,
                              options: LoadOptions = .init()) -> (Task<Void, Never>, OutcomeBox) {
        let box = OutcomeBox()
        let task = Task { @MainActor in
            do {
                _ = try await engine.load(source: source, options: options)
                box.outcome = .returned
            } catch is CancellationError {
                box.outcome = .cancelled
            } catch {
                box.outcome = .failed("\(error)")
            }
        }
        return (task, box)
    }

    /// How long a cancelled load may take to end. What it guards is the wait it replaced: a silent
    /// origin is only given up on by a timeout, the shortest at open being the 5 s HEAD probe and
    /// the ingest's 10 s request timeout, so any ceiling below 5 s tells "the cancel ended it" from
    /// "a timeout ended it". 1.5 s was a guess at the quiet-machine time and a loaded runner took 2 s.
    static let ceiling: Duration = .seconds(4)

    /// A custom source has no timeout to tell the cancel from: the only other end of a parked read
    /// is the reader's own fallback (`ParkedReader` and `RetainedReader` both wait 120 s), so the
    /// bound is derived from that. 4 s failed on a loaded runner that took 7.3 s from the cancel to
    /// the outcome.
    static let customSourceCeiling: Duration = .seconds(ParkedReader.defaultFallback / 2)

    /// Cancels after the load has been held a moment and reports how long it took to end. The wait
    /// has no bound of its own, so a slow end reports its real duration instead of the poll's.
    private static func cancelAndTime(_ task: Task<Void, Never>, _ box: OutcomeBox) async throws -> Duration {
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        try await waitFor { box.outcome != nil }
        return clock.now - cancelledAt
    }

    private static func fixture() throws -> Data { try ProbeTestFixtures.hdr10Plus() }

    @Test("A custom source blocked in its read ends with CancellationError once its task is cancelled")
    func customSourceBlockedInRead() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < Self.customSourceCeiling)
        #expect(reader.wasReleasedByEngine)
        await task.value
        #expect(engine.state == .idle)
        #expect(engine.loadedURL == nil)
    }

    @Test("A URL source whose origin never answers ends with CancellationError once its task is cancelled")
    func urlSourceWithSilentOrigin() async throws {
        let origin = try ProbeHTTPTestOrigin(data: try Self.fixture())
        origin.holdLaterRequests()
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/silent.mp4"))
        let (task, box) = Self.start(engine, .url(url))
        try await waitFor { !origin.requests.isEmpty }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < Self.ceiling)
        origin.stop()
        await task.value
        #expect(engine.state == .idle)
    }

    @Test("A live HLS ingest whose origin never answers ends with CancellationError once its task is cancelled")
    func liveIngestWithSilentOrigin() async throws {
        let origin = try ProbeHTTPTestOrigin(data: Data("#EXTM3U\n".utf8))
        origin.holdLaterRequests()
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/index.m3u8"))
        let reader = HLSLiveIngestReader(playlistURL: url)
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"),
                                     options: LoadOptions(isLive: true))
        try await waitFor { !origin.requests.isEmpty }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < Self.ceiling)
        origin.stop()
        await task.value
        #expect(engine.state == .idle)
    }

    @Test("A live playlist URL rerouted onto the ingest ends with CancellationError once its task is cancelled")
    func liveURLWithSilentOrigin() async throws {
        let origin = try ProbeHTTPTestOrigin(data: Data("#EXTM3U\n".utf8))
        origin.holdLaterRequests()
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/index.m3u8"))
        var options = LoadOptions(isLive: true)
        options.nativeRemoteHLS = false
        let (task, box) = Self.start(engine, .url(url), options: options)
        try await waitFor { !origin.requests.isEmpty }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < Self.ceiling)
        origin.stop()
        await task.value
        #expect(engine.state == .idle)
    }

    @Test("A load issued after a cancelled one plays normally")
    func loadAfterCancelledLoad() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        #expect(box.outcome == .cancelled)

        let probe = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        #expect(probe != nil)
        #expect(engine.loadedURL != nil)
        #expect(engine.state != .idle)
        #expect(engine.errorInfo == nil)
    }

    @Test("Cancelling a load and starting the next in the same turn leaves the next one alone")
    func cancelThenLoadInTheSameTurn() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = ParkedReader()
        let (first, firstBox) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }

        first.cancel()
        let (second, secondBox) = Self.start(
            engine, .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        await first.value
        await second.value
        #expect(firstBox.outcome == .cancelled)
        #expect(secondBox.outcome == .returned)
        #expect(engine.loadedURL != nil)
        #expect(engine.state != .idle)
    }

    @Test("A cancellation that lands after a newer load took over does not touch it")
    func staleCancellationSparesTheSuccessor() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let stale = AetherEngine.LoadAttempt()
        stale.generation = engine.loadGeneration
        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }

        engine.abandonCancelledLoad(stale)
        let touched = try await waitFor(upTo: .milliseconds(300)) { reader.wasReleasedByEngine }
        #expect(!touched)
        #expect(engine.state == .loading)
        task.cancel()
        await task.value
        #expect(box.outcome == .cancelled)
    }

    @Test("A cancellation that lands after the load returned leaves the session playing")
    func lateCancellationSparesTheLoadedSession() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let attempt = AetherEngine.LoadAttempt()
        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        attempt.generation = engine.loadGeneration

        engine.abandonCancelledLoad(attempt)
        #expect(engine.loadedURL != nil)
        #expect(engine.state != .idle)
    }

    @Test("A load started on an already cancelled task throws without tearing down the running session")
    func alreadyCancelledTaskLeavesTheRunningSession() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        let generation = engine.loadGeneration
        let reader = ParkedReader(fallback: 2)

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await engine.load(source: .custom(reader, formatHint: "mpegts"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!reader.entered)
        #expect(engine.loadGeneration == generation)
        #expect(engine.loadedURL != nil)
    }
    @Test("A plain cancel publishes no error on its way to idle")
    func cancelPublishesNoError() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var states: [PlaybackState] = []
        let sub = engine.$state.sink { states.append($0) }
        defer { sub.cancel() }
        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }
        task.cancel()
        await task.value

        #expect(box.outcome == .cancelled)
        #expect(!states.contains { if case .error = $0 { return true } else { return false } }, "\(states)")
        #expect(states.last == .idle)
        #expect(engine.errorInfo == nil)
    }

    @Test("Cancel-then-load keeps the native player the way a newer load would (#15)")
    func cancelKeepsTheNativePlayer() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        let host = try #require(engine.nativeHost)
        let player = try #require(engine.currentAVPlayer)

        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }
        task.cancel()
        await task.value
        #expect(box.outcome == .cancelled)
        #expect(engine.nativeHost === host)
        #expect(engine.currentAVPlayer === player)

        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        #expect(engine.nativeHost === host)
        #expect(engine.currentAVPlayer === player)
    }

    @Test("Cancelling a load that follows an engine rebuild ends the rebuild's load and throws (AE#629)")
    func cancelledFollowerEndsTheRebuild() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let hostReader = ParkedReader()
        let (hostLoad, hostBox) = Self.start(engine, .custom(hostReader, formatHint: "mpegts"))
        try await waitFor { hostReader.entered }
        let generation = engine.loadGeneration

        // The escalation's rebuild: armed for the live generation, claimed by its own load's teardown.
        let rebuildReader = ParkedReader()
        let rebuild = Task { @MainActor in
            _ = try await engine.load(source: .custom(rebuildReader, formatHint: "mpegts"))
        }
        engine.softwarePathRebuild = rebuild
        engine.softwarePathTakeoverArm = generation
        try await waitFor { rebuildReader.entered }
        #expect(engine.softwarePathTakeover?.supersededGeneration == generation)
        #expect(hostBox.outcome == nil)

        let elapsed = try await Self.cancelAndTime(hostLoad, hostBox)
        #expect(hostBox.outcome == .cancelled, "ended \(String(describing: hostBox.outcome)) after \(elapsed)")
        #expect(rebuildReader.wasReleasedByEngine)
        await #expect(throws: CancellationError.self) { try await rebuild.value }
        #expect(engine.state == .idle)
        #expect(engine.errorInfo == nil)
    }
    @Test("A reroute's startup continuation does not outlive a load that was cancelled before it began (#361)")
    func cancelledRerouteWithdrawsItsContinuation() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let before = engine.startupGeneration
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            engine.continueStartupAcrossReroute()
            _ = try await engine.load(source: .custom(ParkedReader(fallback: 2), formatHint: "mpegts"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }

        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        #expect(engine.startupGeneration == before &+ 1)
    }
    /// A reader whose `cancel()` only unblocks the read in flight (the IOReader contract) and whose
    /// `close()` ends it, so a rebuild can park on it again after the probe that preceded it was aborted.
    final class RetainedReader: IOReader, @unchecked Sendable {
        private let condition = NSCondition()
        private var cancels = 0
        private var arrivals = 0
        private var closed = false

        var arrivalCount: Int { condition.withLock { arrivals } }
        var isClosed: Bool { condition.withLock { closed } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            condition.lock()
            defer { condition.unlock() }
            let epoch = cancels
            arrivals += 1
            let deadline = Date().addingTimeInterval(ParkedReader.defaultFallback)
            while !closed, cancels == epoch, condition.wait(until: deadline) {}
            return -1
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() { condition.withLock { closed = true; condition.broadcast() } }
        func cancel() { condition.withLock { cancels += 1; condition.broadcast() } }
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    /// The custom-source rebuild runs `reloadWithAudioOverride` on the retained reader with its probe
    /// detached, which cancelling the rebuild's Task does not reach. Modelled here by that shape.
    @Test("Cancelling a follower ends a retained-reader rebuild that Task cancellation cannot reach (AE#629)")
    func cancelledFollowerEndsARetainedReaderRebuild() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = RetainedReader()
        let (hostLoad, hostBox) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.arrivalCount > 0 }
        let generation = engine.loadGeneration

        let rebuild = Task { @MainActor in
            engine.claimSoftwarePathTakeover()
            engine.stopInternal(resetDisplayCriteria: false, keepCustomReader: true)
            let gen = engine.loadGeneration
            await BlockingWork.detached {
                var byte: UInt8 = 0
                _ = reader.read(&byte, size: 1)
            }.value
            try engine.checkLoadCurrent(gen)
        }
        engine.softwarePathRebuild = rebuild
        engine.softwarePathTakeoverArm = generation
        try await waitFor { engine.softwarePathTakeover != nil && reader.arrivalCount > 1 }

        let elapsed = try await Self.cancelAndTime(hostLoad, hostBox)
        #expect(hostBox.outcome == .cancelled, "ended \(String(describing: hostBox.outcome)) after \(elapsed)")
        #expect(elapsed < Self.customSourceCeiling)
        #expect(reader.isClosed)
        await #expect(throws: CancellationError.self) { try await rebuild.value }
        await hostLoad.value
        #expect(engine.state == .idle)
    }
    @Test("Cancelling a follower ends a rebuild whose load() rerouted into a nested load (AE#629, AE#678)")
    func cancelledFollowerEndsANestedRerouteRebuild() async throws {
        let origin = try ProbeHTTPTestOrigin(data: Data("#EXTM3U\n".utf8))
        origin.holdLaterRequests()
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let hostReader = ParkedReader()
        let (hostLoad, hostBox) = Self.start(engine, .custom(hostReader, formatHint: "mpegts"))
        try await waitFor { hostReader.entered }
        let generation = engine.loadGeneration

        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/index.m3u8"))
        var options = LoadOptions(isLive: true)
        options.nativeRemoteHLS = false
        let rebuild = Task { @MainActor in
            _ = try await engine.load(source: .url(url), options: options)
        }
        engine.softwarePathRebuild = rebuild
        engine.softwarePathTakeoverArm = generation
        try await waitFor { !origin.requests.isEmpty }
        let takeover = try #require(engine.softwarePathTakeover)
        #expect(engine.loadGeneration != takeover.rebuildGeneration)

        let elapsed = try await Self.cancelAndTime(hostLoad, hostBox)
        #expect(hostBox.outcome == .cancelled, "ended \(String(describing: hostBox.outcome)) after \(elapsed)")
        #expect(elapsed < Self.ceiling)
        await #expect(throws: CancellationError.self) { try await rebuild.value }
        origin.stop()
        await hostLoad.value
        #expect(engine.state == .idle)
    }

    /// Serves the fixture, and once armed parks any read from the head of the file (where a reopen
    /// starts) until the engine cancels or closes it.
    final class HeadGatedReader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let condition = NSCondition()
        private var position = 0
        private var armed = false
        private var parkedAtHead = 0

        init(_ bytes: Data) { self.bytes = bytes }

        func arm() { condition.withLock { armed = true } }
        var parkedCount: Int { condition.withLock { parkedAtHead } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            condition.lock()
            defer { condition.unlock() }
            if armed, position == 0 {
                parkedAtHead += 1
                let parked = parkedAtHead
                let deadline = Date().addingTimeInterval(120)
                while armed, parkedAtHead == parked, condition.wait(until: deadline) {}
                return -1
            }
            let n = min(Int(size), bytes.count - position)
            guard n > 0 else { return -1 }
            bytes.withUnsafeBytes { raw in _ = memcpy(buffer, raw.baseAddress! + position, n) }
            position += n
            return Int32(n)
        }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            condition.withLock {
                switch whence {
                case 65536: return Int64(bytes.count)
                case SEEK_SET: position = Int(max(0, min(offset, Int64(bytes.count))))
                case SEEK_CUR: position = max(0, min(position + Int(offset), bytes.count))
                case SEEK_END: position = max(0, min(bytes.count + Int(offset), bytes.count))
                default: return -1
                }
                return Int64(position)
            }
        }
        func close() { condition.withLock { armed = false; condition.broadcast() } }
        func cancel() { condition.withLock { parkedAtHead += 1; condition.broadcast() } }
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    @Test("A custom-source reload a stop() supersedes mid-reopen throws CancellationError and publishes no error")
    func supersededCustomReloadIsACancellation() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = HeadGatedReader(try Self.fixture())
        _ = try await engine.load(source: .custom(reader, formatHint: "mp4"))
        reader.arm()
        let parkedBefore = reader.parkedCount

        let reload = Task { @MainActor in try await engine.reloadAtCurrentPosition() }
        try await waitFor { reader.parkedCount > parkedBefore }
        engine.stop()

        await #expect(throws: CancellationError.self) { try await reload.value }
        #expect(engine.state == .idle)
        #expect(engine.errorInfo == nil)
    }
}
