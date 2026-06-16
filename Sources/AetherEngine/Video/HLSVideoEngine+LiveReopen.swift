import Foundation

extension HLSVideoEngine {

    func handlePumpFinished(_ prod: HLSSegmentProducer,
                                    reason: HLSSegmentProducer.PumpExitReason) {
        guard isLiveSession else { return }
        switch reason {
        case .stopRequested, .muxerFailed:
            return
        case .sourceReplay:
            // The server restarted its stream from the beginning after a
            // reconnect (Jellyfin transcode respawn). Reopening the same
            // URL would replay the same content again, so the in-engine
            // reopen path cannot recover this; only a fresh playback
            // negotiation (new session / URL) gets back to the live edge.
            // Hand it to the host and leave the session parked (AVPlayer
            // drains its buffer while the host retunes).
            EngineLog.emit(
                "[HLSVideoEngine] live source replayed from start after reconnect; "
                + "requesting host retune (fresh playback session)",
                category: .session
            )
            onLiveSourceReset?()
            return
        case .segmentStall:
            // The cutter wedged (hostile SSAI ad pod the direct re-mux
            // can't keep cutting through). An in-engine URL reopen would
            // re-enter the same ad pod, so hand it to the host: the
            // direct-path fallback latch sends it to the server-muxed
            // route, which tolerates the ad pod's timestamp resets.
            EngineLog.emit(
                "[HLSVideoEngine] live segment cutter stalled (likely SSAI ad pod); "
                + "requesting host retune to the server route",
                category: .session
            )
            onLiveSourceReset?()
            return
        case .eof, .readError, .keyframeStarvation:
            // A healthy live source never EOFs; treat it like a loss.
            // A source that cannot be reopened by URL (custom reader, e.g.
            // the live HLS ingest) owns its upstream reconnection itself; by
            // the time the pump exits, the loss is terminal. Re-opening the
            // synthetic custom URL would burn the whole backoff budget on
            // guaranteed failures and then stall silently. Surface the loss
            // to the host instead (same retune surface as a detected source
            // replay); the host re-negotiates or falls back.
            if !sourceReopenableByURL {
                EngineLog.emit(
                    "[HLSVideoEngine] live custom-source pump exited (reason=\(reason)); "
                    + "URL reopen not possible, requesting host retune",
                    category: .session
                )
                onLiveSourceReset?()
                return
            }
        }
        // Counter updates inside the same restartLock section: they are
        // touched by the pump threads of successive producers, and the
        // lock both orders those accesses and pairs them with the
        // provider snapshot.
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

    private func performLiveReopen(failedProducer: HLSSegmentProducer) async {
        for attempt in 1...Self.liveReopenMaxAttempts {
            // Abort silently when the session was torn down (stop() nils
            // the producer) or someone else already replaced it.
            guard currentProducerIs(failedProducer) else { return }

            // Capped exponential backoff: 0.5, 1, 2, 4, 8, 8 s (~23 s
            // total). Enough to ride out a Jellyfin transcode respawn
            // without hammering a dead tuner.
            let delay = min(0.5 * pow(2.0, Double(attempt - 1)), 8.0)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            let dem = Demuxer()
            // Register before the blocking open so stop() can abort it
            // (markClosed); deregister identity-guarded below.
            registerReopenDemuxer(dem)
            defer { unregisterReopenDemuxer(dem) }
            do {
                try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders, isLive: true)
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] live reopen attempt \(attempt)/\(Self.liveReopenMaxAttempts) failed: \(error)",
                    category: .session
                )
                dem.close()
                continue
            }
            // Same channel URL must yield the same stream layout; the
            // reopened producer reuses savedVideoConfig/savedAudioConfig,
            // which embed stream indices and time bases from the
            // original probe. A mismatch means the server handed us a
            // different transcode shape: retry rather than corrupt.
            guard dem.videoStreamIndex == videoStreamIndex else {
                EngineLog.emit(
                    "[HLSVideoEngine] live reopen attempt \(attempt): video stream index "
                    + "changed (\(dem.videoStreamIndex) != \(videoStreamIndex)), retrying",
                    category: .session
                )
                dem.close()
                continue
            }

            switch finishLiveReopen(failedProducer: failedProducer, dem: dem, attempt: attempt) {
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
    }

    /// Synchronous helper for the locked sections of the reopen (NSLock
    /// is unavailable from async contexts).
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

    /// Swap the freshly opened demuxer in and bring up the continuation
    /// producer. Synchronous (locked); called from the async retry loop.
    private func finishLiveReopen(failedProducer: HLSSegmentProducer,
                                  dem: Demuxer,
                                  attempt: Int) -> LiveReopenOutcome {
        restartLock.lock()
        guard producer === failedProducer, let prov = provider else {
            restartLock.unlock()
            dem.close()
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
            // The fresh connection joins the broadcast at "now":
            // content and source clock jump relative to the last
            // delivered segment, so the seam segment carries
            // #EXT-X-DISCONTINUITY and the shift handoff is deferred
            // to the seam (same mechanism as a program-boundary
            // rebase; an immediate onVideoShiftKnown would jump the
            // host clock while pre-loss content is still on screen).
            newProd.firstSegmentDiscontinuous = true
            newProd.onVideoShiftKnown = { [weak self] shiftPts in
                self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: outputEnd)
            }
            producer = newProd
            restartLock.unlock()
            oldDem?.close()
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
            EngineLog.emit(
                "[HLSVideoEngine] live reopen attempt \(attempt): producer build failed (\(error))",
                category: .session
            )
            return .retry
        }
    }
}
