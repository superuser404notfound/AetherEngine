import Foundation

extension HLSVideoEngine {

    /// #126 pure decision: a non-live pump exit on a read error with nothing ever produced
    /// (no packets written, empty segment cache) is a dead source. The playlist exists but no
    /// segment will ever land, so AVPlayer parks in waitingToPlay forever unless this surfaces.
    static func isFatalVODPumpExit(
        reason: HLSSegmentProducer.PumpExitReason,
        isLive: Bool,
        packetsWritten: Int,
        cachedSegments: Int
    ) -> Bool {
        guard !isLive, case .readError = reason else { return false }
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
        case .stopRequested, .muxerFailed, .backpressureWedge:
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

    func handlePumpFinished(_ prod: HLSSegmentProducer,
                                    reason: HLSSegmentProducer.PumpExitReason) {
        // #65 (VOD only): a broken backpressure wedge means AVPlayer is stuck behind a parked producer.
        // Re-anchor the producer on AVPlayer's real position so the segments it is starved for get produced.
        if case .backpressureWedge = reason {
            handleBackpressureWedge()
            return
        }
        // #99 failure mode B: a VOD muxer death (e.g. first cut before any bridged audio packet, so
        // mov_write_moov cannot build the dec3 box) previously had NO recovery arm; the session sat
        // starved forever. Bounded revive through the normal restart path, which rebuilds the muxer
        // and re-arms (post-EOF: rebuilds) the audio bridge.
        if case .muxerFailed = reason, !isLiveSession {
            handleVODMuxerFailure()
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
            if Self.shouldReviveVODAfterReadError(
                isLive: isLiveSession,
                packetsWritten: prod.packetsWrittenCount,
                cachedSegments: cache?.count ?? 0
            ) {
                handleVODReadErrorExit(code)
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] VOD pump died before producing anything "
                    + "(readError \(code)); surfacing fatal source failure",
                    category: .session
                )
                onVODSourceFailed?(code)
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
            handleVODGateStarvationExit(prod)
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
        case .stopRequested, .muxerFailed, .backpressureWedge:
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
            EngineLog.emit(
                "[HLSVideoEngine] live segment cutter stalled (likely SSAI ad pod); "
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
        restartLock.lock()
        let segmentsNow = provider?.liveContinuationPoint().nextIndex ?? 0
        if segmentsNow == lastReopenSegmentCount {
            barrenReopenCycles += 1
        } else {
            barrenReopenCycles = 0
        }
        lastReopenSegmentCount = segmentsNow
        let barrenNow = barrenReopenCycles
        restartLock.unlock()
        if barrenNow >= Self.maxBarrenReopenCycles {
            EngineLog.emit(
                "[HLSVideoEngine] live source produced no segments across "
                + "\(barrenNow) reopen cycles; giving up (source considered dead)",
                category: .session
            )
            if reopenTransport == .customFactory {
                // #199: same last-resort surface as reopen exhaustion; without it the recoverable
                // exit reason skipped the halt above and the zombie session would hold blocking
                // reloads it can never satisfy.
                provider?.markLiveProductionHalted()
                onLiveSourceReset?()
            }
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
    func handleVODReadErrorExit(_ code: Int32) {
        restartLock.lock()
        let admitted = readErrorReviveGate.admit()
        let attempts = readErrorReviveGate.attempts
        let cap = readErrorReviveGate.maxAttempts
        if admitted { mainDemuxerSuspectDead = true }
        restartLock.unlock()
        guard admitted else {
            EngineLog.emit(
                "[HLSVideoEngine] #169 VOD readError revive cap reached "
                + "(\(attempts) failures, cap \(cap)); giving up (source not readable in this session)",
                category: .session
            )
            return
        }
        let frozen = currentPlaybackPositionProvider?() ?? 0
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: frozen, pendingSeekTarget: recoverySeekTargetProvider?(),
            currentRendered: frozen)
        let idx = segmentIndexForPlaylistTime(anchor)
        EngineLog.emit(
            "[HLSVideoEngine] #169 VOD pump died mid-session (readError \(code)); "
            + "rebuilding producer on a fresh demuxer at "
            + "\(String(format: "%.2f", anchor))s -> seg\(idx) "
            + "(attempt \(attempts)/\(cap))",
            category: .session
        )
        requestRestart(at: idx, authoritative: true)
    }

    /// AE#169 round 3: re-anchor a VOD session whose pump starved its scan-forward gate to EOF.
    /// The last keyframe the gate dropped below the target is the final real random-access point
    /// of the file; producing from its segment folds the tail content into the cache so playback
    /// reaches end-of-media (via the tail-park completion) instead of dying at -12889 on a
    /// segment no anchoring can produce. Bounded by its own #99-shaped gate.
    func handleVODGateStarvationExit(_ prod: HLSSegmentProducer) {
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
            return
        }
        guard let idx = Self.planSegmentIndex(forSourcePts: lastKeyPts, plan: plan) else {
            EngineLog.emit(
                "[HLSVideoEngine] #169 VOD gate starved to EOF but the dropped keyframe "
                + "(pts=\(lastKeyPts)) maps to no plan segment; not re-anchoring",
                category: .session
            )
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] #169 VOD gate starved to EOF at seg\(prod.anchoredBaseIndex): "
            + "no keyframe at/after the plan boundary; re-anchoring on the last real keyframe "
            + "(pts=\(lastKeyPts)) -> seg\(idx) (attempt \(attempts)/\(cap))",
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
        // #79: re-anchor authoritatively. The anchor is where recovery must aim (pending seek target,
        // else AVPlayer's real position), so it must win the coalescer's pending slot over any stale
        // in-flight scrub target (else the producer settles at the scrub target and AVPlayer stays starved).
        requestRestart(at: idx, authoritative: true)

        // #93 residual: the producer is re-anchored and can serve, but a stalled AVPlayer sometimes
        // never resumes REQUESTING (zero GETs, waitingToMinimizeStalls forever, item never fails).
        // Watch the provider's fetch counter through a grace window; if the consumer stays silent
        // while it still wants to play, ask the host for a re-engage nudge.
        let fetchesAtReanchor = provider?.mediaFetchCount ?? 0
        let epoch = sessionEpochSnapshot()
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.consumerReengageGraceSeconds * 1_000_000_000))
            guard let self, self.isSessionEpochCurrent(epoch) else { return }
            let fetchesNow = self.provider?.mediaFetchCount ?? 0
            guard fetchesNow == fetchesAtReanchor,
                  self.playIntentProvider?() == true else { return }
            // #115: re-read the position at nudge time. On VOD the consumer keeps rendering
            // buffered segments through the grace window, so the wedge-trip capture is behind
            // the on-screen frame and a zero-tolerance nudge to it replays visibly.
            let freshPos = self.currentPlaybackPositionProvider?() ?? pos
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

    private func performLiveReopen(failedProducer: HLSSegmentProducer) async {
        let transport = Self.liveReopenTransport(
            sourceReopenableByURL: sourceReopenableByURL,
            hasCustomSourceReopenFactory: customSourceReopenFactory != nil)
        for attempt in 1...Self.liveReopenMaxAttempts {
            guard currentProducerIs(failedProducer) else { return }

            let delay = min(0.5 * pow(2.0, Double(attempt - 1)), 8.0)  // capped exponential backoff: 0.5..8s (~23s total)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            let dem = Demuxer()
            registerReopenDemuxer(dem)  // register before blocking open so stop() can abort via markClosed
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
        if transport == .customFactory {
            // #199: the in-engine transport is exhausted; surface the loss the way a factory-less
            // custom source would have immediately, so the host can retune instead of holding a
            // zombie session whose blocking-reload advert can never be satisfied.
            provider?.markLiveProductionHalted()
            onLiveSourceReset?()
        }
    }

    /// NSLock unavailable from async contexts; this synchronous helper wraps the check.
    private func currentProducerIs(_ p: HLSSegmentProducer) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return producer === p
    }

    private func registerReopenDemuxer(_ dem: Demuxer) {
        restartLock.lock()
        reopenDemuxer = dem
        restartLock.unlock()
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
        let (nextIndex, outputEnd) = prov.liveContinuationPoint()
        do {
            let newProd = try makeProducer(
                baseIndex: nextIndex,
                liveReopenOutputEndSeconds: outputEnd
            )
            // Fresh connection joins the broadcast at "now"; source clock jumps, so the seam carries #EXT-X-DISCONTINUITY. Shift handoff deferred to seam to avoid jumping the host clock while pre-loss content is on screen.
            newProd.firstSegmentDiscontinuous = true
            newProd.onVideoShiftKnown = { [weak self] shiftPts in
                self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: outputEnd)
            }
            producer = newProd
            // #199: the new demuxer reads from the factory-vended reader; take ownership so stop()
            // and the next reopen close it. The initial load's reader stays engine-owned.
            let oldReader = reopenCustomReader
            if freshReader != nil { reopenCustomReader = freshReader }
            restartLock.unlock()
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
