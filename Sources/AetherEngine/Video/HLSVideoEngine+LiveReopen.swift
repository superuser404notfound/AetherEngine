import Foundation

extension HLSVideoEngine {

    /// #126 pure decision: a non-live pump exit with nothing ever produced (no packets written,
    /// empty segment cache) is a dead source. The playlist exists but no segment will ever land,
    /// so AVPlayer parks in waitingToPlay forever unless this surfaces.
    ///
    /// EOF counts, and used not to. The restriction to `.readError` did not follow from the
    /// reasoning above (which is about what was produced, not about how the pump died), and it let
    /// a whole class through: a source libavformat can demux but not deliver keyframed packets from
    /// runs to the end of the file, writes nothing, and exits `.eof`. Measured on such a file, the
    /// host sat at `state=playing phase=rebuffering` for the whole session while the provider
    /// answered `404 init.mp4 empty`. What keeps this safe is the produced-nothing condition, not
    /// the reason: an ordinary EOF after real playback has packets and segments behind it.
    ///
    /// Teardown (`.stopRequested`) is excluded because it is not a failure, and the reasons that
    /// own a recovery arm (`.muxerFailed`, `.needsAudioSampleEntryPrime`, `.backpressureWedge`)
    /// never reach this decision: their arms return first.
    static func isFatalVODPumpExit(
        reason: HLSSegmentProducer.PumpExitReason,
        isLive: Bool,
        packetsWritten: Int,
        cachedSegments: Int
    ) -> Bool {
        guard !isLive else { return false }
        switch reason {
        case .readError, .eof: break
        default: return false
        }
        return packetsWritten == 0 && cachedSegments == 0
    }

    /// AE#169 round 3 pure decision: a VOD pump that reached EOF with its scan-forward gate never
    /// opened produced nothing; the plan boundary it targeted has no runtime keyframe at or after
    /// it (tail Cues drift or a mis-flagged tail IRAP; the gate itself is pts-based since round 3).
    /// If the gate saw keyframes below the target while dropping, the last of them is the true
    /// final random-access point and production re-anchors there (bounded), so the tail content
    /// gets produced and end-of-media completes through the tail-park instead of the forward-wait
    /// escalation restarting into the same starve until -12889. A head-of-stream pump (no restart
    /// target) starving means a keyframe-less source, which stays the #126 fatal surface.
    static func shouldReanchorVODAfterGateStarvation(
        isLive: Bool,
        videoGateOpened: Bool,
        hadRestartTarget: Bool,
        lastDroppedKeyframePts: Int64
    ) -> Bool {
        guard !isLive, !videoGateOpened, hadRestartTarget else { return false }
        return lastDroppedKeyframePts != Int64.min
    }

    /// AE#169 round 3 pure decision: the plan segment whose span contains a source pts (the last
    /// index whose startPts is at or below it). nil when the plan is empty or the pts precedes
    /// the first boundary (nowhere sane to re-anchor).
    static func planSegmentIndex(forSourcePts pts: Int64, plan: [Segment]) -> Int? {
        var result: Int? = nil
        for (i, seg) in plan.enumerated() {
            if seg.startPts <= pts { result = i } else { break }
        }
        return result
    }

    /// AE#169 round 2 pure decision: a VOD pump read-error exit that produced media before dying
    /// is revivable (the source worked; a reconnect-churned read failed). The complement is the
    /// #126 dead-source fatal surface; live keeps its reopen machinery.
    static func shouldReviveVODAfterReadError(
        isLive: Bool,
        packetsWritten: Int,
        cachedSegments: Int
    ) -> Bool {
        guard !isLive else { return false }
        return packetsWritten > 0 || cachedSegments > 0
    }

    /// #167 follow-up pure decision: live pump exits that delegate to host retune leave a provider no
    /// producer will ever cut into again. Its blocking-reload advert must drop and its held ?_HLS_msn=
    /// waiters release, or the zombie session (and any item reload against it while the host retunes)
    /// trips -15410 on a hold that cannot be satisfied. Reopenable exits (URL source, or a #199
    /// engine-created ingest reader with a fresh-reader factory) resume cutting into the same provider
    /// and must NOT latch; stop/muxer/backpressure exits have their own arms.
    static func shouldHaltLiveProduction(
        reason: HLSSegmentProducer.PumpExitReason,
        sourceReopenable: Bool
    ) -> Bool {
        switch reason {
        case .segmentStall, .sourceReplay:
            return true
        case .eof, .readError, .keyframeStarvation:
            return !sourceReopenable
        case .stopRequested, .muxerFailed, .backpressureWedge, .needsAudioSampleEntryPrime:
            // muxerFailed / needsAudioSampleEntryPrime: handleLiveMuxerFailure and the AE#222 arm rebuild
            // the producer into the SAME provider, so an eager halt here would 503 the very provider the
            // rebuild is about to serve; both arms halt themselves once their budget is exhausted.
            return false
        }
    }

    /// #199 pure decision: which transport a live pump-exit reopen uses for the fresh source
    /// connection. URL sources reopen by URL (unchanged); an engine-created ingest reader reopens
    /// through its fresh-reader factory; a host-provided custom reader has neither and cannot reopen
    /// in-engine (its exit delegates to host retune as before).
    enum LiveReopenTransport: Equatable {
        case url
        case customFactory
        case none
    }

    static func liveReopenTransport(
        sourceReopenableByURL: Bool, hasCustomSourceReopenFactory: Bool
    ) -> LiveReopenTransport {
        if sourceReopenableByURL { return .url }
        if hasCustomSourceReopenFactory { return .customFactory }
        return .none
    }

    /// Shared budget for both live recovery arms (in-place muxer rebuild, reopen): bounded by PROGRESS,
    /// not per session. A recovery that cut new segments since the last death earns a fresh budget (an
    /// hours-long channel legitimately crosses several encoder restarts, so a session-lifetime gate like
    /// the VOD #99 one would be wrong here), while `cap` consecutive BARREN attempts mean the source is
    /// not usable as-is and the session must halt production and delegate to host retune.
    ///
    /// The progress index is the provider's continuation point, i.e. how many segments have ever been
    /// produced, so "barren" means the last recovery produced nothing at all.
    ///
    /// One deliberate hole, the same one the reopen arm has always had: a source that dies after every
    /// handful of segments never goes barren and so recovers forever. Bounding that needs a rate, not a
    /// counter, and an eager cap would kill exactly the long-running channels this budget exists for.
    static func liveRecoveryBudgetDecision(
        progressIndex: Int,
        lastProgressIndex: Int,
        barrenCycles: Int,
        cap: Int
    ) -> (proceed: Bool, newBarrenCycles: Int) {
        let cycles = progressIndex == lastProgressIndex ? barrenCycles + 1 : 0
        return (cycles < cap, cycles)
    }

    /// #199 follow-up pure decision: EVERY in-engine reopen transport that exhausts its budget must
    /// halt production (dropping the blocking-reload advert, releasing held ?_HLS_msn= waiters) and
    /// surface the loss to the host via onLiveSourceReset. #199 scoped that escalation to the factory
    /// transport it introduced, which left a URL source's exhaustion as a zombie session: provider
    /// un-halted, playlist frozen, host never told to retune. `.none` never reaches an exhaustion
    /// site (it delegates to host retune before any reopen begins) and must stay out so a future
    /// call-site reshuffle cannot double-signal that path.
    ///
    /// Exhaustive on purpose: `.none` is proof that "everything except the factory transport"
    /// was already the wrong shape once, so a transport added later must be classified here by
    /// hand rather than inherit a default that happens to compile.
    static func liveReopenExhaustionEscalatesToHost(transport: LiveReopenTransport) -> Bool {
        switch transport {
        case .url, .customFactory:
            return true
        case .none:
            return false
        }
    }

    /// AE#627: a keyframe starvation on the session's FIRST join (no segment ever produced) while video
    /// kept arriving says the bitstream has no entry point this route accepts, not that the link
    /// hiccupped. The same starvation after segments were produced is a mid-session loss and keeps its
    /// reopens, and a wait that saw no video at all is a source problem a reopen can fix.
    static func liveJoinFoundNoEntryPoint(
        reason: HLSSegmentProducer.PumpExitReason,
        segmentsProduced: Int,
        starvedVideoDrops: Int
    ) -> Bool {
        guard case .keyframeStarvation = reason else { return false }
        return segmentsProduced == 0 && starvedVideoDrops > 0
    }

    /// AE#627: the engine's answer to `onLiveJoinWithoutEntryPoint` when the software path is not on
    /// offer. The reopens this skipped would have ended here too, a minute later.
    func giveUpLiveJoinWithoutEntryPoint() {
        escalateLiveReopenExhaustion(transport: Self.liveReopenTransport(
            sourceReopenableByURL: sourceReopenableByURL,
            hasCustomSourceReopenFactory: customSourceReopenFactory != nil))
    }

    /// The whole escalation, so the two exhaustion sites (barren-cycle cap, reopen attempt cap)
    /// cannot drift apart: the decision plus BOTH of its effects. The halt is the half that is easy
    /// to lose, and losing it is what the -15410 zombie is made of; onLiveSourceReset alone (what
    /// the #65 stall ladder publishes) leaves the dead provider still advertising blocking reloads.
    func escalateLiveReopenExhaustion(transport: LiveReopenTransport) {
        guard Self.liveReopenExhaustionEscalatesToHost(transport: transport) else { return }
        provider?.markLiveProductionHalted()
        onLiveSourceReset?()
    }

    func handlePumpFinished(_ prod: HLSSegmentProducer,
                                    reason: HLSSegmentProducer.PumpExitReason) {
        // Audit HLS-1: a superseded pump (the #79 markClosed of a wedged read, or stop()) reports
        // an aborted read as `.readError`. Acting on it spent the session-lifetime revive gate,
        // doomed the replacement demuxer and queued an authoritative restart at a stale position.
        restartLock.lock()
        let isCurrent = producer === prod
        restartLock.unlock()
        guard isCurrent else {
            if case .stopRequested = reason {} else {
                EngineLog.emit(
                    "[HLSVideoEngine] superseded producer exited (reason=\(reason)); not the session's pump, ignored",
                    category: .session
                )
            }
            return
        }
        // #65 (VOD only): a broken backpressure wedge means AVPlayer is stuck behind a parked producer.
        // Re-anchor the producer on AVPlayer's real position so the segments it is starved for get produced.
        if case .backpressureWedge = reason {
            handleBackpressureWedge()
            return
        }
        // AE#222: the pump deferred its first cut because the audio sample entry is packet-derived
        // (E-AC-3/AC-3/TrueHD) and this source's first segment carries no audio packet, then captured one real
        // audio frame on its way out. Rebuild with that frame as the muxer's moov prime, which keeps the
        // stream-copy (and any Atmos) rather than bridging to FLAC or stretching the first segment.
        if case .needsAudioSampleEntryPrime = reason {
            handleAudioSampleEntryPrimeNeeded(prod)
            return
        }
        // #99 failure mode B: a muxer death (e.g. first cut before any bridged audio packet, so
        // mov_write_moov cannot build the dec3 box) previously had NO recovery arm; the session sat
        // starved forever. VOD: bounded revive through the normal restart path, which rebuilds the muxer
        // and re-arms (post-EOF: rebuilds) the audio bridge. Live: the restart path is VOD-only (empty
        // segmentPlan), so the live arm rebuilds the producer in place on the same connection instead.
        if case .muxerFailed = reason {
            // AE#366: the exit reason is only `.needsAudioSampleEntryPrime` when a frame was actually
            // captured, so a source whose selected track cannot prime the moov arrives HERE. Record
            // the structural verdict before the revive arm rebuilds: without it every attempt pays
            // the full search again (~256 MiB of reads) to reach the same answer.
            if prod.audioMoovPrimeUnobtainable {
                restartLock.lock()
                sessionAudioMoovPrimeUnobtainable = true
                restartLock.unlock()
            }
            // AE#396: a bridged session whose DECODER produced not one frame has nothing a revive can
            // reach. The restart path rebuilds the muxer and re-opens the encoder (#99 failure mode B),
            // and both sit downstream of the arm that failed: the same decoder is handed the same bytes
            // and answers the same way, which is exactly what the reporter measured, three attempts with
            // identical packet counts finishing in 12 to 23 ms. Spend the words instead of the budget.
            // Frames decoded but nothing emitted is the ENCODER side, which a rebuild does heal, so that
            // shape keeps its revive.
            if !isLiveSession, let bridge = prod.audioBridgeFeedStats, bridge.decodedNothing {
                EngineLog.emit(
                    "[HLSVideoEngine] AE#396 the audio bridge decoded nothing, so the mp4 sample entry "
                    + "can never be built and a revive would re-read the same bytes: \(bridge.summary)",
                    category: .session
                )
                surfaceVODSourceFailure(FFmpegErr.einval, "Audio track could not be decoded",
                                        kind: .audioBridgeProducedNoOutput)
                return
            }
            if isLiveSession {
                handleLiveMuxerFailure(prod)
            } else {
                handleVODMuxerFailure()
            }
            return
        }
        // #126: a VOD pump that dies on a read error having produced NOTHING (no packets
        // written, empty segment cache) is a dead source: the playlist exists but no segment
        // will ever land, no restart arm covers readError, and AVPlayer parks in waitingToPlay
        // until the host's first-frame timeout. Surface it as fatal instead of dying silently.
        // AE#169 round 2: a MID-SESSION read error (packets/segments already produced) gets a
        // bounded revive. The old assumption that the scrub/wedge arms cover it was false for a
        // request within the forward-wait window of the dead producer's front: the wedge detector
        // died with the pump and the provider's restart escalation judged by index distance alone,
        // so the tail request parked 30 s at a time into -12889 (rrgomes' seg719 trace).
        if case .readError(let code) = reason, !isLiveSession {
            // A sequential origin admits no revive: the fresh demuxer can only reopen from byte 0
            // and then fails its anchor seek on the non-seekable pb, burning a connection slot on
            // origins that are typically connection-capped. Surface the loss to the host, whose
            // re-request (a fresh load) is the real recovery path.
            if sequentialOriginPinsProducerToZero {
                EngineLog.emit(
                    "[HLSVideoEngine] sequential-origin VOD pump died (readError \(code)); "
                    + "revive cannot resume at an offset, surfacing source failure",
                    category: .session
                )
                surfaceVODSourceFailure(code, "Source read failed")
            } else if Self.shouldReviveVODAfterReadError(
                isLive: isLiveSession,
                packetsWritten: prod.packetsWrittenCount,
                cachedSegments: cache?.count ?? 0
            ) {
                handleVODReadErrorExit(code, deadProducer: prod)
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] VOD pump died before producing anything "
                    + "(readError \(code)); surfacing fatal source failure",
                    category: .session
                )
                surfaceVODSourceFailure(code, "Source read failed")
            }
            return
        }
        // AE#169 round 3: a VOD pump that reached EOF with its scan-forward gate never opened
        // wrote nothing because the targeted plan boundary has no runtime keyframe at or after it
        // (the unproducible tail segment of rrgomes' DV MKV). Re-anchor on the last keyframe the
        // gate dropped instead of returning, which would leave the forward-wait escalation
        // restarting into the same starve.
        if case .eof = reason, Self.shouldReanchorVODAfterGateStarvation(
            isLive: isLiveSession,
            videoGateOpened: prod.videoGateOpened,
            hadRestartTarget: prod.hasRestartTarget,
            lastDroppedKeyframePts: prod.lastPregateDroppedKeyframePts
        ) {
            // Falls through when the re-anchor is spent or has nowhere to aim, so a session that
            // produced nothing still reaches the terminal surface below instead of the bare return
            // this arm used to end on.
            if handleVODGateStarvationExit(prod) { return }
        }
        // Sequential append playlist: TRUE source EOF (not a stop, not a re-anchor) completes
        // the playlist with ENDLIST so AVPlayer can reach end-of-media - a growing playlist
        // without ENDLIST never ends.
        if case .eof = reason, !isLiveSession, sequentialOrigin {
            provider?.markSequentialEnded()
        }
        if Self.isFatalVODPumpExit(
            reason: reason,
            isLive: isLiveSession,
            packetsWritten: prod.packetsWrittenCount,
            cachedSegments: cache?.count ?? 0
        ) {
            EngineLog.emit(
                "[HLSVideoEngine] #126 VOD pump reached \(reason) without producing anything "
                + "(0 packets written, 0 segments cached); surfacing fatal source failure",
                category: .session
            )
            surfaceVODSourceFailure(FFmpegErr.eio, "Source produced no playable media")
            return
        }
        guard isLiveSession else { return }
        let reopenTransport = Self.liveReopenTransport(
            sourceReopenableByURL: sourceReopenableByURL,
            hasCustomSourceReopenFactory: customSourceReopenFactory != nil)
        if Self.shouldHaltLiveProduction(reason: reason, sourceReopenable: reopenTransport != .none) {
            provider?.markLiveProductionHalted()
        }
        switch reason {
        case .stopRequested, .muxerFailed, .backpressureWedge, .needsAudioSampleEntryPrime:
            // muxerFailed and needsAudioSampleEntryPrime never reach here (their arms above return first).
            return
        case .sourceReplay:
            // Server restarted stream from beginning (Jellyfin transcode respawn); URL reopen would replay stale content. Delegate to host for fresh negotiation.
            EngineLog.emit(
                "[HLSVideoEngine] live source replayed from start after reconnect; "
                + "requesting host retune (fresh playback session)",
                category: .session
            )
            onLiveSourceReset?()
            return
        case .segmentStall:
            // SSAI ad pod the cutter can't cut through; URL reopen would re-enter it. Delegate to host for server-muxed fallback.
            //
            // AE#446 round 8: unless the gate never opened, in which case there was no cutter to
            // stall and no pod to blame. Same delegation, but the line has to say which of the two
            // it saw, because the two send a reader looking in different places.
            EngineLog.emit(
                (prod.videoGateOpened
                 ? "[HLSVideoEngine] live segment cutter stalled (likely SSAI ad pod); "
                 : "[HLSVideoEngine] live join produced nothing at all (no video packet ever "
                   + "reached the cutter, so the source is not delivering the video it declares); ")
                + "requesting host retune to the server route",
                category: .session
            )
            onLiveSourceReset?()
            return
        case .eof, .readError, .keyframeStarvation:
            // Host-provided custom readers own their own reconnection and no in-engine transport can
            // rebuild them, so their loss surfaces to the host immediately. #199: engine-created
            // ingest readers DO have a transport (the fresh-reader factory) and fall through into the
            // bounded reopen flow below instead of tearing the whole player session down.
            if reopenTransport == .none {
                EngineLog.emit(
                    "[HLSVideoEngine] live custom-source pump exited (reason=\(reason)); "
                    + "no in-engine reopen transport, requesting host retune",
                    category: .session
                )
                onLiveSourceReset?()
                return
            }
        }
        let segmentsNow = provider?.liveContinuationPoint().nextIndex ?? 0
        if let onLiveJoinWithoutEntryPoint,
           Self.liveJoinFoundNoEntryPoint(
               reason: reason, segmentsProduced: segmentsNow, starvedVideoDrops: prod.starvedVideoDrops) {
            EngineLog.emit(
                "[HLSVideoEngine] AE#627 live join read \(prod.starvedVideoDrops) video packets without an "
                + "entry point the native route can open; a reopen joins the same bitstream, so not reopening",
                category: .session
            )
            onLiveJoinWithoutEntryPoint()
            return
        }
        restartLock.lock()
        let reopenDecision = Self.liveRecoveryBudgetDecision(
            progressIndex: segmentsNow,
            lastProgressIndex: lastReopenSegmentCount,
            barrenCycles: barrenReopenCycles,
            cap: Self.maxBarrenReopenCycles
        )
        barrenReopenCycles = reopenDecision.newBarrenCycles
        lastReopenSegmentCount = segmentsNow
        let barrenNow = reopenDecision.newBarrenCycles
        restartLock.unlock()
        if !reopenDecision.proceed {
            EngineLog.emit(
                "[HLSVideoEngine] live source produced no segments across "
                + "\(barrenNow) reopen cycles; giving up (source considered dead)",
                category: .session
            )
            // #199 follow-up: same last-resort surface for EVERY reopenable transport; the
            // recoverable exit reason skipped the halt above, so without this the zombie
            // session holds blocking reloads it can never satisfy and the host is never told.
            escalateLiveReopenExhaustion(transport: reopenTransport)
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] live pump exited (reason=\(reason)); starting reopen",
            category: .session
        )
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performLiveReopen(failedProducer: prod)
        }
    }

    /// AE#169 round 2: revive a VOD session whose pump died on a mid-session read error. Mirrors
    /// the #99 muxerFailed arm: bounded by its own gate, aimed at the pending seek target or
    /// AVPlayer's real position, authoritative so it wins the coalescer's pending slot. The
    /// demuxer whose read just threw is marked suspect so performRestart replaces it via the #79
    /// fresh-demuxer path instead of seeking the failed connection.
    func handleVODReadErrorExit(_ code: Int32, deadProducer: HLSSegmentProducer? = nil) {
        // #377: the reader knows the difference between a source that is gone and one that is
        // metering us, and loses it on the way here: the give-up arm returns a bare `-1`, FFmpeg
        // renders that as "Operation not permitted", and this is what arrives. Ask the budget,
        // which stamped the refusal when the status was read.
        //
        // The distinction is worth two different behaviours, because a 429 is a NOT-YET. Spending
        // the ordinary two-attempt budget on it burns both attempts inside a minute, each one
        // reopening from byte 0 against an origin that is refusing precisely that, and then
        // declares the source "not readable in this session" while the same stream plays instantly
        // if the user backs out and presses play. That verdict is not just unhelpful, it is false.
        let metered = OriginRequestBudget.shared.refusedRecently(
            sourceURL, within: Self.rateLimitVerdictWindowSeconds)

        restartLock.lock()
        let admitted = metered ? rateLimitReviveGate.admit() : readErrorReviveGate.admit()
        let attempts = metered ? rateLimitReviveGate.attempts : readErrorReviveGate.attempts
        let cap = metered ? 0 : readErrorReviveGate.maxAttempts
        let spent = metered ? rateLimitReviveGate.elapsedSeconds() : 0
        let budget = rateLimitReviveGate.budgetSeconds
        if admitted { mainDemuxerSuspectDead = true }
        restartLock.unlock()
        guard admitted else {
            if metered {
                // #377 round 5: the status code says "refused", it does not say what for, and the
                // two answers need different fixes. The books do carry the difference, and this is
                // the last line a session gets, so it says what they hold rather than asserting the
                // shape the code has been guessing at since round 1.
                EngineLog.emit(
                    "[HLSVideoEngine] #377 VOD refusing-source budget spent "
                    + "(\(String(format: "%.0f", spent))s of \(String(format: "%.0f", budget))s "
                    + "across \(attempts) attempts); giving up. The source is REFUSING us, "
                    + "not lost: retrying this same request later is expected to work, and handing "
                    + "off to another player will meet the same refusal."
                    + OriginRequestBudget.shared.refusalShapeNote(for: sourceURL),
                    category: .session
                )
                surfaceVODSourceFailure(code, "Source is rate limiting this session",
                                        kind: .sourceRateLimited)
                return
            }
            EngineLog.emit(
                "[HLSVideoEngine] #169 VOD readError revive cap reached "
                + "(\(attempts) failures, cap \(cap)); giving up (source not readable in this session)",
                category: .session
            )
            // The session is dead: no producer will be rebuilt and AVPlayer would park
            // in waitingToPlay forever. Surface the same terminal failure as the
            // produced-nothing arm so the host can tear down or retry.
            surfaceVODSourceFailure(code, "Source read failed")
            return
        }
        let frozen = currentPlaybackPositionProvider?() ?? 0
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: frozen, pendingSeekTarget: recoverySeekTargetProvider?(),
            currentRendered: frozen)
        let idx = segmentIndexForPlaylistTime(anchor)

        guard metered else {
            EngineLog.emit(
                "[HLSVideoEngine] #169 VOD pump died mid-session (readError \(code)); "
                + "rebuilding producer on a fresh demuxer at "
                + "\(String(format: "%.2f", anchor))s -> seg\(idx) "
                + "(attempt \(attempts)/\(cap))",
                category: .session
            )
            requestRestart(at: idx, authoritative: true)
            return
        }

        // A refusing origin gets time before the next ask. Reopening immediately is what turned the
        // two ordinary attempts into two more refusals: the request that just failed is reissued
        // against an origin that has not moved. The delay grows per attempt so a session that is
        // inside a refusal window stops re-asking every few seconds without ending.
        let delay = Self.rateLimitReviveDelay(attempt: attempts)
        // #377 round 6: hold the stall on the host's axis for as long as the budget runs. The
        // reader emits `.flowing` as it EXITS, deliberately, so the terminal outcome carries the
        // state; between that exit and the rebuilt reader's first byte there is no reader at all,
        // and the phase said "playing" through minutes in which nothing was being delivered. The
        // reporter's correction to this issue is exactly that window: it is a viewer watching a
        // stalled picture, not accounting.
        onNetworkPhaseChanged?(.reconnecting)
        EngineLog.emit(
            "[HLSVideoEngine] #377 VOD pump died mid-session on a REFUSING origin (readError \(code)); "
            + "waiting \(String(format: "%.0f", delay))s before rebuilding the producer at "
            + "\(String(format: "%.2f", anchor))s -> seg\(idx) (attempt \(attempts), "
            + "\(String(format: "%.0f", spent))s of \(String(format: "%.0f", budget))s spent)",
            category: .session
        )
        let sessionEpoch = sessionEpochSnapshot()
        Task.detached(priority: .userInitiated) { [weak self, weak deadProducer] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.fireMeteredRevive(at: idx, deadProducer: deadProducer, sessionEpoch: sessionEpoch)
        }
    }

    /// Audit HLS-104: the backoff runs 3 to 45 s, and in that time a segment-driven restart, a seek or
    /// a stop may already have replaced the dead producer. Whichever did has the better position.
    static func meteredReviveStillOwed(sessionUnchanged: Bool, deadProducerInstalled: Bool) -> Bool {
        sessionUnchanged && deadProducerInstalled
    }

    func fireMeteredRevive(at idx: Int, deadProducer: HLSSegmentProducer?, sessionEpoch: UInt64) {
        let sessionUnchanged = isSessionEpochCurrent(sessionEpoch)
        let owed = Self.meteredReviveStillOwed(
            sessionUnchanged: sessionUnchanged, deadProducerInstalled: currentProducerIs(deadProducer))
        guard owed else {
            EngineLog.emit(
                "[HLSVideoEngine] #377 metered revive at seg\(idx) skipped: the dead producer was "
                + "already replaced or the session stopped during the backoff",
                category: .session)
            return
        }
        requestRestart(at: idx, authoritative: true)
    }

    /// #377: how long a refusal keeps classifying a read error as metering. The reader's give-up
    /// arm exits within seconds of the last refused status (its own backoff is spent before it
    /// returns), so this only has to cover that gap, not a whole session.
    static let rateLimitVerdictWindowSeconds: TimeInterval = 60

    /// #377: backoff before re-asking a metered origin. Grows per attempt and is capped, so the
    /// last attempts are spaced widely enough to outlast a per-minute quota window.
    static func rateLimitReviveDelay(attempt: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [3, 8, 20, 45]
        guard attempt >= 1 else { return ladder[0] }
        return ladder[min(attempt - 1, ladder.count - 1)]
    }

    /// AE#169 round 3: re-anchor a VOD session whose pump starved its scan-forward gate to EOF.
    /// The last keyframe the gate dropped below the target is the final real random-access point
    /// of the file; producing from its segment folds the tail content into the cache so playback
    /// reaches end-of-media (via the tail-park completion) instead of dying at -12889 on a
    /// segment no anchoring can produce. Bounded by its own #99-shaped gate.
    /// Returns whether a re-anchor was actually requested. False means this arm is done with the
    /// session and the caller decides what a pump that produced nothing means.
    @discardableResult
    func handleVODGateStarvationExit(_ prod: HLSSegmentProducer) -> Bool {
        let lastKeyPts = prod.lastPregateDroppedKeyframePts
        restartLock.lock()
        let plan = segmentPlan
        let admitted = gateStarvationReviveGate.admit()
        let attempts = gateStarvationReviveGate.attempts
        let cap = gateStarvationReviveGate.maxAttempts
        restartLock.unlock()
        guard admitted else {
            EngineLog.emit(
                "[HLSVideoEngine] #169 VOD gate-starvation re-anchor cap reached "
                + "(\(attempts) starved pumps, cap \(cap)); giving up "
                + "(no keyframe at/after the plan boundary in this session)",
                category: .session
            )
            return false
        }
        guard let idx = Self.planSegmentIndex(forSourcePts: lastKeyPts, plan: plan) else {
            EngineLog.emit(
                "[HLSVideoEngine] #169 VOD gate starved to EOF but the dropped keyframe "
                + "(pts=\(lastKeyPts)) maps to no plan segment; not re-anchoring",
                category: .session
            )
            return false
        }
        EngineLog.emit(
            "[HLSVideoEngine] #169 VOD gate starved to EOF at seg\(prod.anchoredBaseIndex): "
            + "no keyframe at/after the plan boundary; re-anchoring on the last real keyframe "
            + "(pts=\(lastKeyPts)) -> seg\(idx) (attempt \(attempts)/\(cap))",
            category: .session
        )
        requestRestart(at: idx, authoritative: true)
        return true
    }

    /// AE#222: rebuild the session with the captured audio frame as the muxer's moov prime.
    ///
    /// The prime is stored on the session, not just handed to the next producer, so every later restart (seek,
    /// audio switch, revive) gets it too: the same video-first interleave defers the first cut of every fresh
    /// muxer, not only the session's first one.
    ///
    /// Aimed like the other revive arms, at the pending seek target or AVPlayer's real position, so a defer
    /// that happens after a scrub resumes where the viewer is.
    func handleAudioSampleEntryPrimeNeeded(_ prod: HLSSegmentProducer) {
        guard let prime = prod.capturedAudioMoovPrimeFrame, !prime.isEmpty else {
            // No frame: the source's audio never showed up inside the scan bounds. Nothing here can keep the
            // stream-copy, so hand the session to the existing muxerFailed recovery.
            EngineLog.emit(
                "[HLSVideoEngine] AE#222 first cut deferred but no audio frame was captured; "
                + "falling back to the muxerFailed recovery",
                category: .session
            )
            if isLiveSession {
                handleLiveMuxerFailure(prod)
            } else {
                handleVODMuxerFailure()
            }
            return
        }

        restartLock.lock()
        let admitted = audioSampleEntryPrimeGate.admit()
        let attempts = audioSampleEntryPrimeGate.attempts
        let cap = audioSampleEntryPrimeGate.maxAttempts
        if admitted { sessionAudioMoovPrimeFrame = prime }
        restartLock.unlock()

        guard admitted else {
            EngineLog.emit(
                "[HLSVideoEngine] AE#222 moov-prime rebuild cap reached (\(attempts) attempts, cap \(cap)); "
                + "falling back to the muxerFailed recovery",
                category: .session
            )
            if isLiveSession {
                handleLiveMuxerFailure(prod)
            } else {
                handleVODMuxerFailure()
            }
            return
        }

        // Live: requestRestart is VOD-only (performRestart bails on the empty live segmentPlan, so the
        // old code path silently rebuilt NOTHING and the session zombified). Rebuild in place instead;
        // the stored session prime flows in through makeProducer.
        if isLiveSession {
            EngineLog.emit(
                "[HLSVideoEngine] AE#222 rebuilding live producer in place with a \(prime.count) B "
                + "audio moov prime (audio stream-copy preserved)",
                category: .session
            )
            Task.detached(priority: .userInitiated) { [weak self] in
                self?.rebuildLiveProducerInPlace(failed: prod)
            }
            return
        }

        let frozen = currentPlaybackPositionProvider?() ?? 0
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: frozen, pendingSeekTarget: recoverySeekTargetProvider?(),
            currentRendered: frozen)
        let idx = segmentIndexForPlaylistTime(anchor)
        EngineLog.emit(
            "[HLSVideoEngine] AE#222 rebuilding producer + muxer with a \(prime.count) B audio moov prime at "
            + "\(String(format: "%.2f", anchor))s -> seg\(idx) (audio stream-copy preserved)",
            category: .session
        )
        requestRestart(at: idx, authoritative: true)
    }

    /// #99: revive a VOD session whose pump died with muxerFailed. The restart path rebuilds the
    /// producer with a fresh muxer and calls audioBridge.startSegment() (which also rebuilds a
    /// post-EOF-drained encoder), so the known transient causes heal. Aimed like the wedge re-anchor:
    /// a pending never-landed seek target owns the recovery aim, else AVPlayer's real position.
    func handleVODMuxerFailure() {
        restartLock.lock()
        let admitted = muxerFailureReviveGate.admit()
        let attempts = muxerFailureReviveGate.attempts
        let cap = muxerFailureReviveGate.maxAttempts
        restartLock.unlock()
        guard admitted else {
            EngineLog.emit(
                "[HLSVideoEngine] #99 VOD muxerFailed revive cap reached "
                + "(\(attempts) failures, cap \(cap)); giving up (source not muxable in this session)",
                category: .session
            )
            // AE#366: this used to be a bare return, and the session then had no producer, no
            // restart and no error: the provider answered `404 init.mp4 empty` forever while
            // AVPlayer sat in waitingToPlay, which reaches the viewer as a permanent black screen
            // with nothing in it to act on. The readError arm above has surfaced its own exhaustion
            // since AE#169; this is the same shape and gets the same last word. -22 is what movenc
            // returns for the moov it cannot write, so the code carries the real cause.
            //
            // AE#396: which cause that is depends on whether the audio was bridged. A silent bridge is
            // not a source that cannot be muxed, it is a source whose audio this engine could not
            // TRANSCODE, and the two ask a host for opposite things: `vodSourceFailed` reads as "the
            // source is gone" and ends a fallback ladder, while a second player that decodes the track
            // itself plays this file. So name the bridge when the bridge is the one that stayed quiet.
            if let bridge = audioBridge?.feedStats, bridge.packetsEmitted == 0 {
                EngineLog.emit(
                    "[HLSVideoEngine] AE#396 the moov was never buildable because the audio bridge "
                    + "emitted nothing this session: \(bridge.summary)",
                    category: .session
                )
                surfaceVODSourceFailure(FFmpegErr.einval, "Audio could not be transcoded for playback",
                                        kind: .audioBridgeProducedNoOutput)
                return
            }
            // [MovieClaw P8] 分片目录因磁盘已满建不出来时，泵失败与音频无关：报存储不足，宿主据此换播放器
            if SegmentCache.storageRecentlyExhausted {
                surfaceVODSourceFailure(FFmpegErr.einval, "Device storage is full: video segments cannot be cached",
                                        kind: .storageExhausted)   // [MovieClaw P25]
                return
            }
            surfaceVODSourceFailure(FFmpegErr.einval, "Source audio cannot be muxed")
            return
        }
        let frozen = currentPlaybackPositionProvider?() ?? 0
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: frozen, pendingSeekTarget: recoverySeekTargetProvider?(),
            currentRendered: frozen)
        let idx = segmentIndexForPlaylistTime(anchor)
        EngineLog.emit(
            "[HLSVideoEngine] #99 VOD pump died with muxerFailed; rebuilding producer + muxer at "
            + "\(String(format: "%.2f", anchor))s -> seg\(idx) "
            + "(attempt \(attempts)/\(cap))",
            category: .session
        )
        requestRestart(at: idx, authoritative: true)
    }

    /// Live arm for a pump death with `muxerFailed`, previously a bare return: the provider kept serving
    /// a frozen playlist, AVPlayer parked on it, and the session zombified until the viewer zapped away.
    /// The connection is healthy (the muxer died, not the socket), so the recovery rebuilds the producer
    /// IN PLACE on the same demuxer and provider at the live continuation point. A reopen is the wrong
    /// tool here: `performLiveReopen` opens its fresh connection BEFORE closing the old demuxer, which
    /// double-connects against a healthy socket and breaks single-connection portals.
    func handleLiveMuxerFailure(_ prod: HLSSegmentProducer) {
        restartLock.lock()
        let nextNow = provider?.liveContinuationPoint().nextIndex ?? 0
        let decision = Self.liveRecoveryBudgetDecision(
            progressIndex: nextNow,
            lastProgressIndex: lastMuxerRebuildSegmentCount,
            barrenCycles: liveMuxerRebuildCycles,
            cap: Self.maxLiveMuxerRebuildCycles
        )
        liveMuxerRebuildCycles = decision.newBarrenCycles
        lastMuxerRebuildSegmentCount = nextNow
        restartLock.unlock()

        guard decision.proceed else {
            EngineLog.emit(
                "[HLSVideoEngine] live muxer died \(decision.newBarrenCycles) times with no new segment; "
                + "halting production and requesting host retune",
                category: .session
            )
            provider?.markLiveProductionHalted()
            onLiveSourceReset?()
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] live pump died with muxerFailed; rebuilding producer in place at "
            + "seg\(nextNow) (barren cycle \(decision.newBarrenCycles)/\(Self.maxLiveMuxerRebuildCycles))",
            category: .session
        )
        // handlePumpFinished runs on the dying pump thread; hop off it like the reopen path does.
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.rebuildLiveProducerInPlace(failed: prod)
        }
    }

    /// `finishLiveReopen` minus the fresh connection: same demuxer, same provider, produced timeline
    /// continues at the live continuation point behind #EXT-X-DISCONTINUITY (the dead pump dropped its
    /// pending look-behind packets; the join gate re-syncs at the next IDR). `sessionAudioMoovPrimeFrame`
    /// flows in through `makeProducer`.
    func rebuildLiveProducerInPlace(failed: HLSSegmentProducer) {
        restartLock.lock()
        guard producer === failed, let prov = provider else {
            restartLock.unlock()
            return
        }
        let (nextIndex, outputEnd) = prov.liveContinuationPoint()
        do {
            let newProd = try makeProducer(
                baseIndex: nextIndex,
                liveReopenOutputEndSeconds: outputEnd
            )
            newProd.firstSegmentDiscontinuous = true
            let newEpoch = newProd.epoch
            newProd.onVideoShiftKnown = { [weak self] shiftPts, _, _ in
                self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: outputEnd, producerEpoch: newEpoch)
            }
            producer = newProd
            restartLock.unlock()
            retireProducer(failed)   // AE#443: the session's totals outlive the producer that held them
            newProd.start()
            EngineLog.emit(
                "[HLSVideoEngine] live producer rebuilt in place: continuing at seg\(nextIndex) "
                + "(outputEnd=\(String(format: "%.1f", outputEnd))s)",
                category: .session
            )
        } catch {
            restartLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] live in-place producer rebuild failed (\(error)); "
                + "halting production and requesting host retune",
                category: .session
            )
            provider?.markLiveProductionHalted()
            onLiveSourceReset?()
        }
    }

    /// #65: re-base the producer onto AVPlayer's real (lagging) position after a VOD backpressure wedge.
    /// The producer was parked 10 segments ahead of a frozen consumer target; re-anchoring to where AVPlayer
    /// actually is puts the starved segments back into the producible window so AVPlayer can resume and land.
    /// Capped so a truly dead AVPlayer (never resumes requesting) can't drive an endless restart storm.
    func handleBackpressureWedge() {
        guard let pos = currentPlaybackPositionProvider?() else {
            EngineLog.emit(
                "[HLSVideoEngine] #65 backpressure wedge but no AVPlayer position available; cannot re-anchor",
                category: .session
            )
            return
        }
        // #358: a re-anchor cannot fill a plan index the cutter never opened, it only rebuilds the
        // same boundaries and folds it again. One fold can still come out producible after a rebase,
        // so the second one is the proof that this recovery reproduces its own trigger. Spending the
        // remaining attempts on it buys a minute of frozen picture and then silence, which is how
        // this reached a reporter (#358); fail the source instead, so the host has something to act on.
        if let fold = provider?.consumerTargetFold, fold.folds >= Self.foldsProvingUnrecoverableGap {
            EngineLog.emit(
                "[HLSVideoEngine] #358 consumer is blocked on seg\(fold.index), which \(fold.folds) pumps "
                + "have now folded away (no IRAP reaches its plan boundary). A re-anchor rebuilds the same "
                + "gap, so the source cannot be played past it; failing instead of re-anchoring.",
                category: .session
            )
            surfaceVODSourceFailure(FFmpegErr.eio, "Source segment could not be produced")
            return
        }

        restartLock.lock()
        // Reset the storm counter when AVPlayer's position has advanced since the last wedge (real progress);
        // a frozen position across consecutive wedges means AVPlayer never recovered, so we eventually give up.
        if pos > lastWedgeReanchorPosition + 0.5 {
            consecutiveWedgeReanchors = 0
        }
        lastWedgeReanchorPosition = pos
        consecutiveWedgeReanchors += 1
        let attempts = consecutiveWedgeReanchors
        restartLock.unlock()

        guard attempts <= Self.maxConsecutiveWedgeReanchors else {
            EngineLog.emit(
                "[HLSVideoEngine] #65 backpressure wedge re-anchor cap reached "
                + "(\(attempts) consecutive at pos=\(String(format: "%.2f", pos))s); giving up (AVPlayer not resuming). "
                + "Engine clock already reconciled by the seek-deadline path.",
                category: .session
            )
            return
        }

        // #93 retest: a pending user seek that never landed owns the recovery aim. AVPlayer only
        // requests media at the seek TARGET after a hard zero-tolerance seek, so a producer
        // re-anchored on the frozen clock fills a window nobody fetches (and can evict the target's
        // segments from retention). Same decision the nudge and stage-2 reload already apply.
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: pos, pendingSeekTarget: recoverySeekTargetProvider?(),
            currentRendered: pos)
        let idx = segmentIndexForPlaylistTime(anchor)
        EngineLog.emit(
            "[HLSVideoEngine] #65 backpressure wedge: re-anchoring producer to "
            + "\(String(format: "%.2f", anchor))s -> seg\(idx)"
            + (anchor != pos ? " (requested seek target; frozen clock \(String(format: "%.2f", pos))s)" : " (AVPlayer position)")
            + " (attempt \(attempts)/\(Self.maxConsecutiveWedgeReanchors))",
            category: .session
        )
        // AE#421: the two repairs are not interchangeable, and which one goes first is decided by
        // whether the consumer could have the content it is silent about. Measured twice by the
        // reporter, on an Apple TV and on a Mac: the producer had already served, the re-anchor
        // changed nothing for the whole six-second grace (zero fetches), and the nudge that followed
        // landed the seek in 240 ms. A re-anchor is the repair for a consumer STARVED of content
        // nobody is producing. A consumer silent on a segment that is already on disk is not
        // starved, and re-anchoring there throws the pump's forward work away to rebuild what it
        // already has (the reporting run put it back from seg15 to seg3).
        if Self.wedgeRepair(targetStored: provider?.hasStoredSegment(at: idx) ?? false) == .nudgeConsumerFirst {
            EngineLog.emit(
                "[HLSVideoEngine] #421 backpressure wedge with seg\(idx) already stored: the consumer "
                + "is silent on content it can have, so nudging it before touching the producer "
                + "(pos=\(String(format: "%.2f", anchor))s, attempt \(attempts)/\(Self.maxConsecutiveWedgeReanchors))",
                category: .session
            )
            onConsumerReengageNeeded?(anchor)
            // The nudge is cheap and reversible, but it is not guaranteed: if the consumer is still
            // silent after the grace, fall back to the re-anchor rather than leaving it wedged.
            afterGraceIfConsumerStaysSilent(capturedPosition: pos) { [weak self] _ in
                guard let self else { return }
                EngineLog.emit(
                    "[HLSVideoEngine] #421 nudge did not re-engage the consumer within "
                    + "\(Int(Self.consumerReengageGraceSeconds))s; re-anchoring producer to seg\(idx) after all",
                    category: .session
                )
                self.requestRestart(at: idx, authoritative: true)
            }
            return
        }

        // #79: re-anchor authoritatively. The anchor is where recovery must aim (pending seek target,
        // else AVPlayer's real position), so it must win the coalescer's pending slot over any stale
        // in-flight scrub target (else the producer settles at the scrub target and AVPlayer stays starved).
        requestRestart(at: idx, authoritative: true)

        // #93 residual: the producer is re-anchored and can serve, but a stalled AVPlayer sometimes
        // never resumes REQUESTING (zero GETs, waitingToMinimizeStalls forever, item never fails).
        // Watch the provider's fetch counter through a grace window; if the consumer stays silent
        // while it still wants to play, ask the host for a re-engage nudge.
        afterGraceIfConsumerStaysSilent(capturedPosition: pos) { [weak self] freshPos in
            guard let self else { return }
            EngineLog.emit(
                "[HLSVideoEngine] #65 consumer re-engage: no segment fetch for "
                + "\(Int(Self.consumerReengageGraceSeconds))s after wedge re-anchor "
                + "(pos=\(String(format: "%.2f", freshPos))s"
                + (freshPos != pos ? ", wedge capture \(String(format: "%.2f", pos))s" : "")
                + "); asking host to nudge AVPlayer",
                category: .session
            )
            self.onConsumerReengageNeeded?(freshPos)
        }
    }

    /// AE#421: which repair a wedge calls for.
    enum WedgeRepair: Equatable {
        /// The target is not produced: the consumer has nothing to fetch, so move the producer.
        case reanchorProducer
        /// The target is on disk: the consumer is silent about content it can have, so move IT.
        case nudgeConsumerFirst
    }

    static func wedgeRepair(targetStored: Bool) -> WedgeRepair {
        return targetStored ? .nudgeConsumerFirst : .reanchorProducer
    }

    /// Run `follow` once the grace window has passed WITHOUT the consumer fetching anything, so a
    /// repair that took effect is never followed by a second one. `follow` receives the position
    /// re-read at that moment (#115: on VOD the consumer keeps rendering buffered segments through
    /// the window, so the trip capture is behind the on-screen frame and acting on it replays
    /// visibly).
    private func afterGraceIfConsumerStaysSilent(
        capturedPosition: Double, _ follow: @escaping @Sendable (Double) -> Void
    ) {
        let fetchesBefore = provider?.mediaFetchCount ?? 0
        let epoch = sessionEpochSnapshot()
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.consumerReengageGraceSeconds * 1_000_000_000))
            guard let self, self.isSessionEpochCurrent(epoch) else { return }
            guard (self.provider?.mediaFetchCount ?? 0) == fetchesBefore,
                  self.playIntentProvider?() == true else { return }
            follow(self.currentPlaybackPositionProvider?() ?? capturedPosition)
        }
    }

    private func performLiveReopen(failedProducer: HLSSegmentProducer) async {
        let transport = Self.liveReopenTransport(
            sourceReopenableByURL: sourceReopenableByURL,
            hasCustomSourceReopenFactory: customSourceReopenFactory != nil)
        for attempt in 1...Self.liveReopenMaxAttempts {
            guard currentProducerIs(failedProducer) else { return }

            let delay = min(0.5 * pow(2.0, Double(attempt - 1)), 8.0)  // capped exponential backoff: 0.5..8s (~23s total)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            let dem = Demuxer()
            // Audit HLS-2: a zap during the sleep above must not open the old channel; on a
            // single-slot tuner that orphan open takes the slot the new channel needs.
            guard registerReopenDemuxer(dem, failedProducer: failedProducer) else { return }
            defer { unregisterReopenDemuxer(dem) }
            var freshReader: IOReader?
            do {
                switch transport {
                case .url:
                    try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders, profile: openProfile, isLive: true)
                case .customFactory:
                    // #199: fresh engine-created ingest reader over the same channel; the dead
                    // reader's construction inputs are immutable, so this rejoins at the live edge.
                    guard let vend = customSourceReopenFactory?() else {
                        EngineLog.emit(
                            "[HLSVideoEngine] #199 live reopen attempt \(attempt)/\(Self.liveReopenMaxAttempts): "
                            + "factory vended no reader",
                            category: .session
                        )
                        continue
                    }
                    freshReader = vend.reader
                    try dem.open(reader: vend.reader, formatHint: vend.formatHint, profile: openProfile, isLive: true)
                case .none:
                    return  // handlePumpFinished already delegated this exit to host retune
                }
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] live reopen attempt \(attempt)/\(Self.liveReopenMaxAttempts) failed: \(error)",
                    category: .session
                )
                dem.close()
                freshReader?.close()
                continue
            }
            // Reopened producer reuses savedVideoConfig/savedAudioConfig (stream indices + time bases from original probe); layout mismatch means server changed transcode shape.
            guard dem.videoStreamIndex == videoStreamIndex else {
                EngineLog.emit(
                    "[HLSVideoEngine] live reopen attempt \(attempt): video stream index "
                    + "changed (\(dem.videoStreamIndex) != \(videoStreamIndex)), retrying",
                    category: .session
                )
                dem.close()
                freshReader?.close()
                continue
            }

            switch finishLiveReopen(failedProducer: failedProducer, dem: dem,
                                    freshReader: freshReader, attempt: attempt) {
            case .done, .aborted:
                return
            case .retry:
                continue
            }
        }
        EngineLog.emit(
            "[HLSVideoEngine] live reopen FAILED after \(Self.liveReopenMaxAttempts) attempts; "
            + "source considered permanently lost",
            category: .session
        )
        // #199 follow-up: the in-engine transport is exhausted; surface the loss the way a
        // factory-less custom source would have immediately, so the host can retune instead of
        // holding a zombie session whose blocking-reload advert can never be satisfied.
        escalateLiveReopenExhaustion(transport: transport)
    }

    /// NSLock unavailable from async contexts; this synchronous helper wraps the check.
    private func currentProducerIs(_ p: HLSSegmentProducer?) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return producer === p
    }

    /// Registers `dem` for `stop()` to abort, atomically with the check that the session still
    /// belongs to `failedProducer`. False means a stop or a newer producer already took over.
    func registerReopenDemuxer(_ dem: Demuxer, failedProducer: HLSSegmentProducer) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard producer === failedProducer else { return false }
        reopenDemuxer = dem
        return true
    }

    private func unregisterReopenDemuxer(_ dem: Demuxer) {
        restartLock.lock()
        if reopenDemuxer === dem { reopenDemuxer = nil }
        restartLock.unlock()
    }

    private enum LiveReopenOutcome { case done, aborted, retry }

    private func finishLiveReopen(failedProducer: HLSSegmentProducer,
                                  dem: Demuxer,
                                  freshReader: IOReader?,
                                  attempt: Int) -> LiveReopenOutcome {
        restartLock.lock()
        guard producer === failedProducer, let prov = provider else {
            restartLock.unlock()
            dem.close()
            freshReader?.close()
            return .aborted
        }
        let oldDem = demuxer
        demuxer = dem
        // #433: the reopen replaces the reader the phase axis describes. The lost source's reader parked
        // the host on `.stalled`, and this demuxer was never handed the sink at all, so the axis kept
        // reporting a transport that no longer exists for the rest of the session.
        oldDem?.onNetworkPhaseChanged = nil
        dem.onNetworkPhaseChanged = onNetworkPhaseChanged
        dem.playIntentProvider = playIntentProvider   // #377: the reopened held connection is bounded by a pause, not by a parked producer
        let (nextIndex, outputEnd) = prov.liveContinuationPoint()
        do {
            let newProd = try makeProducer(
                baseIndex: nextIndex,
                liveReopenOutputEndSeconds: outputEnd
            )
            // Fresh connection joins the broadcast at "now"; source clock jumps, so the seam carries #EXT-X-DISCONTINUITY. Shift handoff deferred to seam to avoid jumping the host clock while pre-loss content is on screen.
            newProd.firstSegmentDiscontinuous = true
            let newEpoch = newProd.epoch
            newProd.onVideoShiftKnown = { [weak self] shiftPts, _, _ in
                self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: outputEnd, producerEpoch: newEpoch)
            }
            producer = newProd
            // #199: the new demuxer reads from the factory-vended reader; take ownership so stop()
            // and the next reopen close it. The initial load's reader stays engine-owned.
            let oldReader = reopenCustomReader
            if freshReader != nil { reopenCustomReader = freshReader }
            restartLock.unlock()
            // AE#443: the swap is final only here; the catch below puts `oldDem` back, and folding it
            // there would count the same reader's bytes twice. A reopen replaces the reader and the
            // producer, not the session's totals.
            retireProducer(failedProducer)
            retireDemuxer(oldDem)
            oldDem?.close()
            if freshReader != nil { oldReader?.close() }
            newProd.start()
            EngineLog.emit(
                "[HLSVideoEngine] live reopen succeeded on attempt \(attempt): "
                + "continuing at seg\(nextIndex) (outputEnd=\(String(format: "%.1f", outputEnd))s)",
                category: .session
            )
            return .done
        } catch {
            demuxer = oldDem
            // The swap did not happen: the axis goes back to the reader that is still installed (#433).
            dem.onNetworkPhaseChanged = nil
            oldDem?.onNetworkPhaseChanged = onNetworkPhaseChanged
            restartLock.unlock()
            dem.close()
            freshReader?.close()
            EngineLog.emit(
                "[HLSVideoEngine] live reopen attempt \(attempt): producer build failed (\(error))",
                category: .session
            )
            return .retry
        }
    }
}
