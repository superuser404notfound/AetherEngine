import Foundation
import Testing
@testable import AetherEngine

/// Audit LIF-101: the CORE-2 owed background decision settled on any move out of `.loading`, and a
/// native load passes through `.paused` (the item's readiness, landing inside the tvOS play gate)
/// seconds before it returns. The tvOS teardown that followed bumped the generation under the load,
/// and the host's `load()` threw the `CancellationError` that means "a newer load or stop took
/// over". Sodalite reads it exactly that way: no observers, no start report, a spinner forever.
///
/// The lifecycle itself is iOS / tvOS only; the owed funnel is not, so these drive it through
/// `noteDidEnterBackground()` and a policy seam that performs the same synchronous teardown.
@Suite("A background decision owed during a load waits for the load to return", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct BackgroundDecisionWaitsForLoadTests {

    /// A fixture served from memory whose first read parks until the test lets it through, so a
    /// load can be held in flight for as long as a test needs.
    final class HeldDataReader: IOReader, @unchecked Sendable {
        private let data: DataIOReader
        private let condition = NSCondition()
        private var released = false
        private var arrivals = 0

        init(_ bytes: Data) { data = DataIOReader(data: bytes) }

        var entered: Bool { condition.withLock { arrivals > 0 } }
        func release() { condition.withLock { released = true; condition.broadcast() } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            condition.lock()
            arrivals += 1
            while !released { condition.wait() }
            condition.unlock()
            return data.read(buffer, size: size)
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { data.seek(offset: offset, whence: whence) }
        func close() { release() }
        func cancel() { release() }
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    /// The states the owed decision was made in, one per decision.
    final class PolicyRuns {
        var states: [PlaybackState] = []
    }

    private static func installPolicy(on engine: AetherEngine) -> PolicyRuns {
        let runs = PolicyRuns()
        engine.owedBackgroundPolicyForTesting = { engine in
            runs.states.append(engine.state)
            engine.releaseVideoPipelineForBackground()
        }
        return runs
    }

    private static func fixture() throws -> Data { try ProbeTestFixtures.hdr10Plus() }

    @Test("A load in flight holds the decision whatever state it passes through")
    func settleMatrix() {
        #expect(!AetherEngine.backgroundDecisionSettles(state: .paused, loadInFlight: true))
        #expect(!AetherEngine.backgroundDecisionSettles(state: .playing, loadInFlight: true))
        #expect(AetherEngine.backgroundDecisionSettles(state: .paused, loadInFlight: false))
        #expect(AetherEngine.backgroundDecisionSettles(state: .playing, loadInFlight: false))
        #expect(!AetherEngine.backgroundDecisionSettles(state: .loading, loadInFlight: false))
        #expect(!AetherEngine.backgroundDecisionSettles(state: .seeking, loadInFlight: false))
    }

    @Test("load() returns normally when the app backgrounds mid-load, and the teardown follows it (audit LIF-101)")
    func loadReturnsThenTheTeardownRuns() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let runs = Self.installPolicy(on: engine)
        let reader = HeldDataReader(try Self.fixture())
        let load = Task { @MainActor in
            try await engine.load(source: .custom(reader, formatHint: "mp4"))
        }
        try await waitFor { reader.entered }

        engine.noteDidEnterBackground()
        // The readiness waypoint `.loading -> .paused` the native load passes through mid-flight.
        engine.state = .paused
        let decidedMidLoad = try await waitFor(upTo: .milliseconds(300)) { !runs.states.isEmpty }
        #expect(!decidedMidLoad)
        reader.release()

        let probe = try await load.value
        #expect(probe != nil)
        try await waitFor { !runs.states.isEmpty }
        #expect(runs.states == [.playing])
        #expect(engine.state == .paused)
        #expect(engine.loadedURL != nil)
    }

    @Test("With no load in flight an owed decision still settles on the state edge (audit CORE-2)")
    func owedSeekStillSettlesOnTheState() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        let runs = Self.installPolicy(on: engine)
        engine.state = .seeking

        engine.noteDidEnterBackground()
        engine.state = .playing

        try await waitFor { !runs.states.isEmpty }
        #expect(runs.states == [.playing])
        #expect(engine.state == .paused)
    }

    @Test("A PiP window closed in the background during a load tears the session down once it settles (audit LIF-105)")
    func pictureInPictureClosedMidLoadIsOwed() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        let runs = Self.installPolicy(on: engine)
        // Backgrounded with a PiP window keeping the session alive, so nothing was owed.
        engine.noteDidEnterBackground()

        let reader = HeldDataReader(try Self.fixture())
        let load = Task { @MainActor in
            try await engine.load(source: .custom(reader, formatHint: "mp4"))
        }
        try await waitFor { reader.entered }
        engine.settleBackgroundDecisionAfterPictureInPictureClosed()
        let decidedMidLoad = try await waitFor(upTo: .milliseconds(300)) { !runs.states.isEmpty }
        #expect(!decidedMidLoad)
        reader.release()

        _ = try await load.value
        try await waitFor { !runs.states.isEmpty }
        #expect(runs.states == [.playing])
        #expect(engine.state == .paused)
    }
}
