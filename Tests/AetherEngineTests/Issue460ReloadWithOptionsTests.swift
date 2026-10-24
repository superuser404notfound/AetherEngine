import Foundation
import Testing
@testable import AetherEngine

/// AE#460: `reloadAtCurrentPosition(applying:)` is the session-preserving rebuild with the options
/// it replays taken from the host. These pin the two rules that make handing a host the whole
/// `LoadOptions` struct safe: the fields that name the session are refused by name, and a refusal
/// leaves the session exactly as it was.
@MainActor
struct Issue460SessionOptionCorrectionTests {

    @Test("the identity list is a real subset of the struct, so a rename cannot leave a dead entry")
    func identityFieldsExist() {
        for field in SessionOptionCorrection.loadIdentityFields {
            #expect(SessionOptionCorrection.knownFields.contains(field),
                    "loadIdentityFields names \(field), which LoadOptions no longer carries")
        }
    }

    /// The inventory guard. A field added to `LoadOptions` is correctable by default (it falls
    /// through `refusedFields`), which is right for a tuning lever and wrong for one that names the
    /// session, so adding one has to be a decision. This fails until someone makes it.
    @Test("every LoadOptions field is accounted for as identity or as correctable")
    func fieldInventoryIsComplete() {
        let actual = Mirror(reflecting: LoadOptions()).children.compactMap(\.label)
        // LoadOptions changed shape. Decide for each new field whether it names the session (add
        // it to loadIdentityFields) or tunes it, then update knownFields.
        #expect(actual == SessionOptionCorrection.knownFields)
    }

    @Test("a tuning change is honoured")
    func tuningChangeIsHonoured() {
        var base = LoadOptions()
        base.audioBridgeMode = .surroundCompat
        var proposed = base
        proposed.audioBridgeMode = .lossless
        proposed.httpHeaders["Authorization"] = "Bearer fresh"
        #expect(SessionOptionCorrection.refusedFields(from: base, to: proposed).isEmpty)
    }

    @Test("each load-identity field is refused by name")
    func identityChangesAreRefused() {
        let base = LoadOptions()
        var live = base; live.isLive = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: live) == ["isLive"])
        var audioOnly = base; audioOnly.audioOnly = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: audioOnly) == ["audioOnly"])
        var hls = base; hls.nativeRemoteHLS = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: hls) == ["nativeRemoteHLS"])
        var sequential = base; sequential.sequentialOrigin = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: sequential) == ["sequentialOrigin"])
    }

    @Test("diagnostic identity cannot be added, removed or changed by an internal reload")
    func diagnosticIdentityChangesAreRefused() {
        let context = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        var current = LoadOptions()
        var proposed = current
        proposed.sourceDiagnosticsContext = context
        #expect(SessionOptionCorrection.refusedFields(from: current, to: proposed) == ["sourceDiagnosticsContext"])
        current = proposed
        let replacements: [SourceNetworkDiagnostics.Context?] = [
            nil,
            .init(playbackID: UUID(), attemptID: context.attemptID),
            .init(playbackID: context.playbackID, attemptID: UUID())
        ]
        for replacement in replacements {
            proposed.sourceDiagnosticsContext = replacement
            #expect(SessionOptionCorrection.refusedFields(from: current, to: proposed) == ["sourceDiagnosticsContext"])
        }
    }

    @Test("an equal diagnostic identity permits a tuning correction")
    func equalDiagnosticIdentityAllowsTuning() {
        let context = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        var current = LoadOptions()
        current.sourceDiagnosticsContext = context
        var proposed = current
        proposed.sourceDiagnosticsContext = .init(playbackID: context.playbackID, attemptID: context.attemptID)
        #expect(SessionOptionCorrection.refusedFields(from: current, to: proposed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: current, to: proposed).isEmpty)
        proposed.audioDelaySeconds = 0.5
        #expect(SessionOptionCorrection.refusedFields(from: current, to: proposed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: current, to: proposed) == ["audioDelaySeconds"])
    }

    @Test("several identity changes are all named, not just the first")
    func identityChangesAreAllNamed() {
        let base = LoadOptions()
        var proposed = base
        proposed.isLive = true
        proposed.sequentialOrigin = true
        proposed.autoplay = false
        #expect(SessionOptionCorrection.refusedFields(from: base, to: proposed)
                == ["isLive", "sequentialOrigin"])
    }

    @Test("changedFields names what moved and stays quiet when nothing did")
    func changedFieldsNamesTheChange() {
        let base = LoadOptions()
        #expect(SessionOptionCorrection.changedFields(from: base, to: base).isEmpty)
        var proposed = base
        proposed.autoplay = false
        proposed.teletextPage = 888
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed)
                == ["autoplay", "teletextPage"])
    }

    /// `String(describing:)` on a Dictionary iterates in hash order, which depends on the storage
    /// capacity, so two equal `httpHeaders` built differently can describe differently. The struct's
    /// own `==` short-circuits the identical case, so the hazard only shows when some OTHER field
    /// moved: the log line would then name a header change nobody made.
    @Test("equal headers built at different capacities do not report a change")
    func headerOrderDoesNotFakeAChange() {
        var base = LoadOptions()
        base.httpHeaders = ["Authorization": "Bearer a", "Referer": "https://example.test", "User-Agent": "x"]
        var proposed = base
        var rebuilt: [String: String] = [:]
        rebuilt.reserveCapacity(256)
        rebuilt["User-Agent"] = "x"
        rebuilt["Referer"] = "https://example.test"
        rebuilt["Authorization"] = "Bearer a"
        proposed.httpHeaders = rebuilt
        proposed.autoplay = false
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed) == ["autoplay"])
    }

    @Test("a real header change is still reported")
    func headerChangeIsReported() {
        var base = LoadOptions()
        base.httpHeaders = ["Authorization": "Bearer stale"]
        var proposed = base
        proposed.httpHeaders["Authorization"] = "Bearer fresh"
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed) == ["httpHeaders"])
    }
}

@MainActor
struct Issue460ReloadWithOptionsTests {

    @Test("a session that was never loaded says why it cannot be rebuilt")
    func refusalIsReadableWithoutAttemptingTheReload() throws {
        let engine = try AetherEngine()
        #expect(engine.sessionReloadRefusal == .noActiveSession)
    }

    @Test("no session throws instead of returning like the plain reload does")
    func noSessionThrows() async throws {
        let engine = try AetherEngine()
        await #expect(throws: AetherEngineError.self) {
            try await engine.reloadAtCurrentPosition { $0.autoplay = false }
        }
        do {
            try await engine.reloadAtCurrentPosition { $0.autoplay = false }
            Issue.record("expected a refusal")
        } catch let error as AetherEngineError {
            guard case .sessionNotReloadable(let refusal) = error else {
                Issue.record("expected sessionNotReloadable, got \(error)")
                return
            }
            #expect(refusal == .noActiveSession)
        }
    }

    @Test("an identity change is refused before the session is even consulted")
    func identityChangeIsRefusedFirst() async throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.isLive = true
        engine.setLoadedOptionsForTesting(seeded)

        do {
            try await engine.reloadAtCurrentPosition { $0.isLive = false }
            Issue.record("expected a refusal")
        } catch let error as AetherEngineError {
            guard case .loadIdentityNotCorrectable(let fields) = error else {
                Issue.record("expected loadIdentityNotCorrectable, got \(error)")
                return
            }
            #expect(fields == ["isLive"])
        }
        // The refusal costs nothing: no teardown, and the session keeps the options it was on.
        #expect(engine.loadedOptions.isLive)
    }

    @Test("a diagnostic identity correction refuses before teardown or tuning installation")
    func diagnosticIdentityRefusesBeforeTeardown() async throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.sourceDiagnosticsContext = .init(playbackID: UUID(), attemptID: UUID())
        engine.setLoadedOptionsForTesting(seeded)
        let url = URL(string: "https://example.test/movie.mkv")!
        engine.loadedURL = url
        engine.state = .playing
        let generation = engine.loadGeneration
        do {
            try await engine.reloadAtCurrentPosition {
                $0.sourceDiagnosticsContext = .init(playbackID: UUID(), attemptID: UUID())
                $0.audioDelaySeconds = 0.5
            }
            Issue.record("expected a diagnostic identity refusal")
        } catch let error as AetherEngineError {
            guard case .loadIdentityNotCorrectable(let fields) = error else {
                Issue.record("expected loadIdentityNotCorrectable, got \(error)")
                return
            }
            #expect(fields == ["sourceDiagnosticsContext"])
        }
        #expect(engine.loadedOptions == seeded)
        #expect(engine.loadedURL == url)
        #expect(engine.state == .playing)
        #expect(engine.loadGeneration == generation)
    }

    @Test("a refused correction does not install the options it refused")
    func refusedCorrectionDoesNotInstall() async throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.autoplay = true
        seeded.teletextPage = 150
        engine.setLoadedOptionsForTesting(seeded)

        // Refused for the session, not for the fields: the tuning change rides along and must not
        // survive a reload that never happened.
        _ = try? await engine.reloadAtCurrentPosition {
            $0.autoplay = false
            $0.teletextPage = 888
        }
        #expect(engine.loadedOptions.autoplay)
        #expect(engine.loadedOptions.teletextPage == 150)
    }

    @Test("the closure is seeded with what the session runs on, not with a fresh struct")
    func closureSeesTheSessionsOptions() async throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.httpHeaders = ["Authorization": "Bearer stale"]
        seeded.matchContentEnabled = true
        engine.setLoadedOptionsForTesting(seeded)

        var seenHeader: String?
        var seenMatchContent: Bool?
        _ = try? await engine.reloadAtCurrentPosition {
            seenHeader = $0.httpHeaders["Authorization"]
            seenMatchContent = $0.matchContentEnabled
        }
        #expect(seenHeader == "Bearer stale")
        #expect(seenMatchContent == true)
    }

    @Test("the correction is installed so internal reopens replay it")
    func correctionInstallsIntoTheSession() throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.httpHeaders = ["Authorization": "Bearer stale"]
        seeded.sourceDiagnosticsContext = .init(playbackID: UUID(), attemptID: UUID())
        engine.setLoadedOptionsForTesting(seeded)

        var corrected = seeded
        corrected.httpHeaders["Authorization"] = "Bearer fresh"
        engine.applySessionOptionCorrection(corrected)
        #expect(engine.loadedOptions.httpHeaders["Authorization"] == "Bearer fresh")
        #expect(engine.loadedOptions.sourceDiagnosticsContext == seeded.sourceDiagnosticsContext)
    }
}

/// AE#464 round 3 (cmcpherson274, read off the code at 6.81.0): `autoplay` was accepted by the
/// correction, named inside `#460: reload applying ...` and then overwritten by the session's own
/// transport. Neither refused nor applied is a real third answer, and it is the one the log could
/// not give: the docs had said so since round 2, but a host reads the log while its correction is
/// happening and the two read very differently there.
@Suite("AE#464 round 3: a field the session owns is not a field the reload applies")
struct Issue464SessionOwnedFieldTests {

    @Test("the session-owned list is a real subset of the struct and names no identity field")
    func inventoryHolds() {
        for field in SessionOptionCorrection.sessionOwnedFields {
            #expect(SessionOptionCorrection.knownFields.contains(field),
                    "sessionOwnedFields names \(field), which LoadOptions no longer carries")
            #expect(!SessionOptionCorrection.loadIdentityFields.contains(field),
                    "\(field) cannot be both refused and quietly owned")
        }
    }

    @Test("what the session owns is split out of what the reload applies")
    func partitionSplitsTheChange() {
        let split = SessionOptionCorrection.partitionChanges(
            ["httpHeaders", "autoplay", "teletextPage"], sessionOwnsTransport: true)
        #expect(split.applied == ["httpHeaders", "teletextPage"])
        #expect(split.sessionOwned == ["autoplay"])
    }

    @Test("a correction that changes nothing else reports no applied field rather than one")
    func autoplayAloneAppliesNothing() {
        let split = SessionOptionCorrection.partitionChanges(["autoplay"], sessionOwnsTransport: true)
        #expect(split.applied.isEmpty)
        #expect(split.sessionOwned == ["autoplay"])
    }

    @Test("the resume after a background teardown has no transport to read, so the flag decides")
    func tornDownSessionAppliesTheMountFlag() {
        // #357: `reloadAtCurrentPosition` replays the mount flag exactly as before on that path,
        // because there is no session transport left to preserve. The log has to match the code:
        // the one rebuild that DOES apply the field must not be told it does not.
        let split = SessionOptionCorrection.partitionChanges(
            ["httpHeaders", "autoplay"], sessionOwnsTransport: false)
        #expect(split.applied == ["httpHeaders", "autoplay"])
        #expect(split.sessionOwned.isEmpty)
    }

    @Test("an ordinary correction is untouched by the split")
    func tuningFieldsPassThrough() {
        let split = SessionOptionCorrection.partitionChanges(
            ["audioDelaySeconds"], sessionOwnsTransport: true)
        #expect(split.applied == ["audioDelaySeconds"])
        #expect(split.sessionOwned.isEmpty)
    }
}

/// AE#464 round 4 (cmcpherson274, measured at 7.1.3): the third answer was in the log and nowhere
/// else. `reloadAtCurrentPosition(applying:)` returned `Void`, threw only for a refusal, and ran the
/// full teardown for a field the rebuild decides for itself, so a host wrapper reported `done` for a
/// correction that changed nothing and paid a visible restart for it (202 ms and a second native
/// host on his rig). The answer is now returned rather than logged at, and it costs no rebuild.
@MainActor
struct Issue464SessionOwnedCorrectionOutcomeTests {

    private func seededEngine(autoplay: Bool) throws -> AetherEngine {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.autoplay = autoplay
        engine.setLoadedOptionsForTesting(seeded)
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        return engine
    }

    @Test("a correction the session owns comes back without a rebuild")
    func sessionOwnedCorrectionSkipsTheRebuild() async throws {
        let engine = try seededEngine(autoplay: true)
        let outcome = try await engine.reloadAtCurrentPosition { $0.autoplay = false }
        #expect(outcome.applied.isEmpty)
        #expect(outcome.sessionOwned == ["autoplay"])
        #expect(outcome.rebuilt == false)
    }

    @Test("the session keeps its own value, the same answer the rebuild gave")
    func sessionOwnedCorrectionInstallsNothing() async throws {
        // The reload writes `sessionRebuildResumesPlaying` over the mount flag before it replays the
        // options, so a correction to `autoplay` never outlived the call. Installing it on the
        // short-circuit alone would make the field mean one thing travelling by itself and another
        // with a header riding along.
        let engine = try seededEngine(autoplay: true)
        _ = try await engine.reloadAtCurrentPosition { $0.autoplay = false }
        #expect(engine.loadedOptions.autoplay == true)
    }

    @Test("a refusal is still a refusal, not a session-owned no-op")
    func refusalWinsOverTheShortCircuit() async throws {
        // Both answers are reachable from one call, and the order matters: a correction naming an
        // identity field AND a session-owned one has to throw rather than return quietly.
        let engine = try seededEngine(autoplay: true)
        await #expect(throws: AetherEngineError.self) {
            try await engine.reloadAtCurrentPosition {
                $0.autoplay = false
                $0.isLive = true
            }
        }
    }

    @Test("the outcome carries the partition the log names")
    func outcomeMirrorsThePartition() {
        let outcome = SessionOptionCorrectionOutcome(
            applied: ["httpHeaders"], sessionOwned: ["autoplay"], rebuilt: true)
        #expect(outcome.applied == ["httpHeaders"])
        #expect(outcome.sessionOwned == ["autoplay"])
        #expect(outcome.rebuilt)
    }
}
