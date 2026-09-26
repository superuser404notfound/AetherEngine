import Foundation

/// AE#561: the rung under every native recovery, taken when AVPlayer refuses the media itself.
///
/// The recoveries above this one all answer the same bytes again: the #93 revive reloads the item at
/// the position that died, and the stage-2 chain refills the same segment. Against a transient that
/// is exactly right. Against a segment Apple's parser refuses on its merits it is a loop, and the
/// reporter's capture shows it ending the session with the replacement item dying 62 ms after the
/// first. `SoftwarePlaybackHost` decodes with libavcodec, which skips such a frame and plays on, and
/// it reads the demuxer directly rather than the loopback HLS, so it steps around a local-server
/// wedge too.
///
/// The rebuild is `reloadAtCurrentPosition(applying:)`, which keeps the session: same playhead, same
/// subtitle carryover, same external-track registry. Its own `decodePathRefusal` is what decides
/// whether the software path can serve this source at all, so a source it cannot serve costs a
/// refusal here rather than a second dead session.
extension AetherEngine {

    /// Rebuild this session on the software path, once, because the native one refused the media.
    @MainActor
    func escalateToSoftwarePath(_ request: SoftwarePathEscalation.Request) async {
        guard SoftwarePathEscalation.shouldEscalate(
            errorDomain: request.domain,
            availability: SoftwarePathEscalation.Availability(
                alreadyEscalated: softwarePathEscalationBudget.isSpent,
                preferredDecodePath: loadedOptions.preferredDecodePath,
                nativeRemoteHLS: loadedOptions.nativeRemoteHLS,
                hostAllowsEscalation: loadedOptions.escalatesToSoftwarePath
            )
        ) else { return }
        // The host's probe read mount-time options and the #93 rung does not consult it at all, so
        // the decision is made again here, against what the session is actually running on.
        guard softwarePathEscalationBudget.take() else { return }

        let absorbed = Self.absorbedFailure(request)
        let duringStartup = waitingLoadGenerations.contains(loadGeneration)
        // AE#629 round 3: the position the rebuild resumes at, not the host's reading at the refusal.
        // Under a mount a load() of the host's own raised, AVPlayer's clock reads the start of the
        // segment it decodes up from until the mount seek lands (12.00 s under 15.90 s on the
        // reporter's box), so the event and the rebuild disagreed by that gap.
        let resumesAt = positionForSessionRebuild

        let verdict = request.domain == SoftwarePathEscalation.liveJoinErrorDomain
            ? "the native route cannot open this live bitstream"
            : "AVPlayer refused the media (\(request.domain)/\(request.code))"
        EngineLog.emit(
            "[AetherEngine] #561 \(verdict) at "
            + "\(String(format: "%.2f", resumesAt))s; rebuilding this session on the "
            + "software path, which decodes it with libavcodec instead"
            + (duringStartup ? " (the waiting load follows it)" : "") + ": \(request.message)",
            category: .engine
        )
        softwarePathEscalations.send(SoftwarePathEscalationEvent(
            absorbedFailure: absorbed,
            positionSeconds: resumesAt,
            duringStartup: duringStartup))

        let rebuild = startTakeoverRebuild { $0.preferredDecodePath = .software }

        do {
            try await rebuild.value
            EngineLog.emit(
                "[AetherEngine] #561 rebuilt on the software path", category: .engine)
        } catch is CancellationError {
            // Audit CORE-1: a stop() or a new load() superseded the rebuild. The session this
            // failure belonged to is gone, and `.error` would land on whatever replaced it.
            EngineLog.emit(
                "[AetherEngine] #561 software rebuild superseded; nothing to surface",
                category: .engine)
        } catch {
            // AE#629: a rebuild that failed after its teardown has already surfaced its own failure,
            // and a load() that followed it threw that same error. Publishing the absorbed one on top
            // would hand the host two `.error`s for one failure, the second contradicting the throw.
            // The absorbed failure is not lost: `softwarePathEscalations` carried it.
            if case .error = state {
                EngineLog.emit(
                    "[AetherEngine] #561 the software rebuild failed after its teardown (\(error)); "
                    + "its own failure is the one surfaced",
                    category: .engine)
                return
            }
            // The rung is gone and the failure was never surfaced, so it has to be surfaced here or
            // the session would sit on a picture that stopped with nothing said.
            EngineLog.emit(
                "[AetherEngine] #561 the software path cannot serve this session (\(error)); "
                + "surfacing the original failure",
                category: .engine
            )
            publishError(absorbed)
        }
    }

    /// Start a rebuild of this session that the engine decided on itself (AE#561 software path, AE#641
    /// video-only), in a shape a `load()` still waiting on the session's startup can follow.
    ///
    /// AE#629: that load is about to be superseded by the rebuild's own. It follows the rebuild instead
    /// of unwinding, and the rebuild continues its #361 startup sequence rather than dropping the
    /// host's bar back to zero.
    @MainActor
    func startTakeoverRebuild(applying change: @escaping @Sendable (inout LoadOptions) -> Void) -> Task<Void, Error> {
        let supersededGeneration = loadGeneration
        let duringStartup = waitingLoadGenerations.contains(supersededGeneration)
        let rebuild = Task { @MainActor in
            // Both are armed where nothing can run before the rebuild's teardown consumes them, and
            // withdrawn after, for the paths that never reach one (a correction refused up front).
            // The takeover is only CLAIMED by that teardown, and only if the session it ends is still
            // the one that failed: a rebuild refused before it tore anything down, or a host stop()
            // that got in first, must leave the waiting load to unwind as the host's own.
            // The failure's session is already gone: rebuilding now would tear down its successor.
            guard self.loadGeneration == supersededGeneration else { throw CancellationError() }
            if duringStartup { self.continueStartupAcrossReroute() }
            self.softwarePathTakeoverArm = supersededGeneration
            defer {
                self.abandonStartupContinuation()
                self.softwarePathTakeoverArm = nil
            }
            _ = try await self.reloadAtCurrentPosition(applying: change)
        }
        softwarePathRebuild = rebuild
        return rebuild
    }

    /// Called by a teardown about to end `loadGeneration`: when that teardown is the engine's own
    /// rebuild, a `load()` still waiting on the ended generation follows the rebuild (AE#629).
    @MainActor
    func claimSoftwarePathTakeover() {
        guard let armed = softwarePathTakeoverArm else { return }
        softwarePathTakeoverArm = nil
        guard armed == loadGeneration, let rebuild = softwarePathRebuild else { return }
        softwarePathTakeover = SoftwarePathEscalation.Takeover(
            supersededGeneration: armed, rebuild: rebuild)
    }

    /// The failure an escalation takes instead of surfacing, in the shape it would have surfaced in.
    nonisolated static func absorbedFailure(_ request: SoftwarePathEscalation.Request) -> PlaybackErrorInfo {
        PlaybackErrorInfo(
            kind: .nativeItemFailed,
            message: request.message,
            underlyingDomain: request.domain.isEmpty ? nil : request.domain,
            underlyingCode: request.code == 0 ? nil : request.code
        )
    }
}
