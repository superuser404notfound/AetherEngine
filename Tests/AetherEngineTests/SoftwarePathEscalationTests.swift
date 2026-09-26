// The last rung under a native session AVPlayer will not play (AE#561).
//
// Every recovery above it reloads the same item against the same bytes, which is the right answer to
// a transient and a loop against a segment Apple's parser refuses on its merits. This decides when
// the engine's own decoder is offered the session instead of the failure being made terminal.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Software-path escalation (AE#561)")
struct SoftwarePathEscalationTests {

    private static func availability(
        escalated: Bool = false,
        path: DecodePath = .automatic,
        remoteHLS: Bool = false,
        hostAllows: Bool = true
    ) -> SoftwarePathEscalation.Availability {
        SoftwarePathEscalation.Availability(
            alreadyEscalated: escalated, preferredDecodePath: path, nativeRemoteHLS: remoteHLS,
            hostAllowsEscalation: hostAllows)
    }

    private static let mediaFailure = SoftwarePathEscalation.Request(
        domain: SoftwarePathEscalation.mediaErrorDomain, code: -19602,
        message: "item death at a frozen position", positionSeconds: 12)

    @Test("A media failure on a fresh native session is escalated")
    func mediaFailureEscalates() {
        #expect(SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability()))
    }

    /// The domain is the whole discriminator: a second decoder can disagree about the media, and
    /// cannot disagree about a source neither path can read.
    @Test("A source failure is not escalated, whatever its code")
    func sourceFailureIsNotEscalated() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: NSURLErrorDomain, availability: Self.availability()))
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "AVFoundationErrorDomain", availability: Self.availability()))
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: nil, availability: Self.availability()))
    }

    @Test("The session spends its escalation once")
    func onlyOnce() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability(escalated: true)))
    }

    @Test("A session already on the software path has nowhere to escalate to")
    func alreadySoftware() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability(path: .software)))
    }

    /// The bypass has no local muxer and the engine decodes nothing on it, so #461 ignores the
    /// option there; escalating would spend a rebuild to arrive where it started.
    @Test("The remote-HLS bypass is not escalated")
    func remoteHLSIsRefused() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability(remoteHLS: true)))
    }

    @Test("No answer from the engine is never a reason to swallow a failure")
    func noAvailabilityRefuses() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: nil))
    }

    @Test("The budget is spent by the first taker, not by the second")
    func budgetIsTakenOnce() {
        let budget = SoftwarePathEscalation.Budget()
        #expect(!budget.isSpent)
        #expect(budget.take())
        #expect(budget.isSpent)
        #expect(!budget.take())
    }

    /// Audit CORE-1: the rebuild is a full load(), and a stop() landing inside it unwinds that load
    /// with a CancellationError. The escalation read every throw as "the software path cannot serve
    /// this session" and published `.error` onto an engine the viewer had already left.
    @Test("A rebuild superseded by stop() leaves the engine idle, not in error", .timeLimit(.minutes(2)))
    @MainActor
    func supersededRebuildIsSilent() async throws {
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus(), stage: .headers)
        defer { origin.stop() }
        let engine = try AetherEngine()
        engine.loadedURL = try #require(URL(string: "http://127.0.0.1:\(origin.port)/source.mkv"))

        let escalation = Task { @MainActor in
            await engine.escalateToSoftwarePath(SoftwarePathEscalation.Request(
                domain: SoftwarePathEscalation.mediaErrorDomain, code: 0,
                message: "item death at a frozen position", positionSeconds: 0))
        }
        // The rebuild's probe is parked on the origin, so the stop lands inside the load.
        try await waitFor { origin.blocked.entered }
        engine.stop()
        origin.stop()
        await escalation.value

        #expect(engine.state == .idle)
        #expect(engine.errorInfo == nil)
    }

    // MARK: - AE#629: a host with its own fallback ladder

    /// The switch is the ask's first form: a declining host gets the failure its ladder reads.
    @Test("A host that declines the rung is never escalated")
    func hostDeclines() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: "CoreMediaErrorDomain", availability: Self.availability(hostAllows: false)))
    }

    @Test("The rung is on by default and correctable on a playing session")
    func defaultAndCorrectable() {
        #expect(LoadOptions().escalatesToSoftwarePath)
        var proposed = LoadOptions()
        proposed.escalatesToSoftwarePath = false
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: proposed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: LoadOptions(), to: proposed)
            == ["escalatesToSoftwarePath"])
    }

    @Test("A declined rung spends nothing and says nothing")
    @MainActor
    func declinedEngineSideSpendsNothing() async throws {
        let engine = try AetherEngine()
        engine.applySessionOptionCorrection(LoadOptions(escalatesToSoftwarePath: false))
        var events: [SoftwarePathEscalationEvent] = []
        let sub = engine.softwarePathEscalations.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.escalateToSoftwarePath(Self.mediaFailure)

        #expect(events.isEmpty)
        #expect(!engine.softwarePathEscalationBudget.isSpent)
        #expect(engine.softwarePathTakeover == nil)
    }

    /// The ask's second form. Measured by the reporter: a host that heard only `videoRoute` could not
    /// tell the rescue from a routing decision.
    @Test("A taken rung publishes the failure it absorbed, at the position the rebuild resumes", .timeLimit(.minutes(2)))
    @MainActor
    func takenRungIsPublished() async throws {
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus(), stage: .headers)
        defer { origin.stop() }
        let engine = try AetherEngine()
        engine.loadedURL = try #require(URL(string: "http://127.0.0.1:\(origin.port)/source.mkv"))
        // AE#629 round 3, measured by the reporter: a mount raised by a load() of the host's own was
        // refused while AVPlayer's clock read 12.00 s, the start of the segment under the 15.90 s the
        // load was handed. The rebuild resumed at 15.90 s and the event said 12.00 s.
        engine.state = .loading
        engine.positionUnderReconstruction = 15.9
        var events: [SoftwarePathEscalationEvent] = []
        let sub = engine.softwarePathEscalations.sink { events.append($0) }
        defer { sub.cancel() }

        let escalation = Task { @MainActor in await engine.escalateToSoftwarePath(Self.mediaFailure) }
        try await waitFor { origin.blocked.entered }
        engine.stop()
        origin.stop()
        await escalation.value

        #expect(events == [SoftwarePathEscalationEvent(
            absorbedFailure: PlaybackErrorInfo(
                kind: .nativeItemFailed, message: "item death at a frozen position",
                underlyingDomain: "CoreMediaErrorDomain", underlyingCode: -19602),
            positionSeconds: 15.9,
            duringStartup: false)])
    }

    /// Reported as a code reading on AE#629: a rebuild whose load failed after its teardown had
    /// already published that failure, and the rung then published the absorbed one on top, so the
    /// host saw two `.error`s for one failure and the second contradicted what `load()` threw.
    @Test("A rebuild that fails after its teardown surfaces one failure, its own", .timeLimit(.minutes(2)))
    @MainActor
    func failedRebuildSurfacesOnce() async throws {
        let engine = try AetherEngine()
        // A port nothing listens on: the rebuild tears the session down and its open is refused.
        engine.loadedURL = try #require(URL(string: "http://127.0.0.1:9/source.mkv"))
        var errors: [PlaybackErrorInfo?] = []
        let sub = engine.$state.sink { state in
            if case .error = state { errors.append(engine.errorInfo) }
        }
        defer { sub.cancel() }

        await engine.escalateToSoftwarePath(Self.mediaFailure)

        #expect(errors.count == 1)
        #expect(errors.first??.kind != .nativeItemFailed)
    }

    /// A custom source whose first read parks until the engine cancels it: a load that cannot finish
    /// and cannot time out, so the takeover is decided against a startup that is really in flight.
    final class ParkedReader: IOReader, @unchecked Sendable {
        private let condition = NSCondition()
        private var released = false
        private var arrivals = 0
        var entered: Bool { condition.withLock { arrivals > 0 } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            condition.lock(); defer { condition.unlock() }
            arrivals += 1
            while !released { condition.wait() }
            return -1
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { whence == 65536 ? 1 << 20 : offset }
        func close() { cancel() }
        func cancel() { condition.withLock { released = true; condition.broadcast() } }
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    /// The ask's third form. A load() the rebuild superseded used to throw the same
    /// CancellationError as a load the host superseded itself, and the reporter's host read it as a
    /// failed load and stopped the rebuilt session. It now follows the rebuild and returns when the
    /// rebuild does; before this change the same load threw at once.
    @Test("A load followed across a takeover returns when the rebuild comes back", .timeLimit(.minutes(2)))
    @MainActor
    func followedLoadReturnsOnRebuild() async throws {
        let engine = try AetherEngine()
        let reader = ParkedReader()
        let (rebuildGate, finishRebuild) = AsyncStream<Void>.makeStream()

        let hostLoad = Task { @MainActor in
            try await engine.load(source: .custom(reader, formatHint: "matroska"),
                                  options: LoadOptions(suppressDisplayCriteria: true))
        }
        try await waitFor { reader.entered }
        let generation = engine.loadGeneration
        #expect(engine.waitingLoadGenerations.contains(generation))

        // What the escalation's rebuild does at its teardown: arm, then claim for the live generation.
        engine.softwarePathRebuild = Task { for await _ in rebuildGate {} }
        engine.softwarePathTakeoverArm = generation
        engine.claimSoftwarePathTakeover()
        engine.stop()

        // The load has unwound its own session and is parked on the rebuild, not finished.
        try await waitFor { engine.loadGeneration != generation }
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.waitingLoadGenerations.contains(generation))

        finishRebuild.finish()
        _ = try await hostLoad.value
        #expect(engine.waitingLoadGenerations.isEmpty)
    }

    /// The other half of the same contract: a rebuild refused before it tore anything down never
    /// owned the session, so the waiting load is still the host's and a host stop() ends it with the
    /// CancellationError it always threw. Here the refusal is `customSourceNotSeekable`, because the
    /// probe that would establish seekability is the one still parked.
    @Test("A rebuild refused before its teardown leaves the waiting load to the host", .timeLimit(.minutes(2)))
    @MainActor
    func refusedRebuildTakesNothingOver() async throws {
        let engine = try AetherEngine()
        let reader = ParkedReader()
        var events: [SoftwarePathEscalationEvent] = []
        let sub = engine.softwarePathEscalations.sink { events.append($0) }
        defer { sub.cancel() }

        let hostLoad = Task { @MainActor in
            try await engine.load(source: .custom(reader, formatHint: "matroska"),
                                  options: LoadOptions(suppressDisplayCriteria: true))
        }
        try await waitFor { reader.entered }

        await engine.escalateToSoftwarePath(Self.mediaFailure)
        #expect(events.map(\.duringStartup) == [true])
        #expect(engine.softwarePathTakeover == nil)
        #expect(engine.softwarePathTakeoverArm == nil)
        #expect(engine.errorInfo?.kind == .nativeItemFailed)

        engine.stop()
        await #expect(throws: CancellationError.self) { try await hostLoad.value }
    }

    /// A rebuild refused before it tore anything down, or one a host stop() beat to the teardown,
    /// never became the session's owner, so the load it would have taken over is still the host's.
    @Test("Only the rebuild's own teardown of the failed generation claims the takeover")
    @MainActor
    func takeoverIsClaimedOnlyByItsOwnTeardown() throws {
        let engine = try AetherEngine()
        engine.softwarePathRebuild = Task {}

        engine.softwarePathTakeoverArm = engine.loadGeneration &+ 1
        engine.claimSoftwarePathTakeover()
        #expect(engine.softwarePathTakeover == nil)
        #expect(engine.softwarePathTakeoverArm == nil)

        engine.softwarePathTakeoverArm = engine.loadGeneration
        engine.claimSoftwarePathTakeover()
        #expect(engine.softwarePathTakeover?.supersededGeneration == engine.loadGeneration)
        #expect(engine.softwarePathTakeoverArm == nil)
    }
}
