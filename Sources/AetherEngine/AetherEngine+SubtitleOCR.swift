import Foundation

// Phase D: selection-armed worker feeding a bitmap track's native WebVTT rendition with
// OCR-recognized text cues, so PGS/DVB/DVD subtitles survive PiP / AirPlay / external display
// on the native path. Packet source is the session SubtitlePacketStore (#112 harvest); decode
// runs on the MainActor tick (overlay-drainer cost class), Vision runs in the detached task.
extension AetherEngine {

    /// Arm for the selected embedded bitmap track. The per-ordinal cursor survives re-arming.
    func startSubtitleOCRWorker(ordinal: Int, streamIndex: Int32) {
        cancelSubtitleOCRWorker()
        guard let store = nativeStore(atOrdinal: ordinal) else { return }
        subtitleOCRArmedOrdinal = ordinal
        let language = ordinal < nativeSubtitleTrackTable.count
            ? nativeSubtitleTrackTable[ordinal].language : nil
        EngineLog.emit("[SubtitleOCR] worker armed: ordinal=\(ordinal) stream=\(streamIndex)", category: .engine)
        subtitleOCRWorkerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let batch = await MainActor.run { [weak self] in
                    self?.subtitleOCRCollectTick(ordinal: ordinal, streamIndex: streamIndex) ?? []
                }
                if !batch.isEmpty {
                    SubtitleImageOCR.appendRecognized(cues: batch, language: language, to: store)
                }
                try? await Task.sleep(nanoseconds: AetherEngine.subtitleDrainTickNanoseconds)
            }
        }
    }

    /// Track switch / deselect / teardown. Cursors and pending stay (see load/stop reset).
    func cancelSubtitleOCRWorker() {
        subtitleOCRArmedOrdinal = nil
        subtitleOCRWorkerTask?.cancel()
        subtitleOCRWorkerTask = nil
        subtitleOCRSidecarFillTask?.cancel()
        subtitleOCRSidecarFillTask = nil
        subtitleOCRDecoder = nil
    }

    /// Load/stop teardown: forget covered-region state too (new session, new axis).
    func resetSubtitleOCRState() {
        cancelSubtitleOCRWorker()
        subtitleOCRCursors.removeAll()
        subtitleOCRPendingStates.removeAll()
    }

    /// MainActor tick: plan the window (drainer pacing, larger lead), decode the stored packets
    /// (bounded per tick), resolve composition ends, return CLOSED cues for off-main OCR.
    private func subtitleOCRCollectTick(ordinal: Int, streamIndex: Int32) -> [SubtitleCue] {
        guard let packetStore = activeSubtitlePacketStore else { return [] }
        let playhead = sourceTime
        var pending = subtitleOCRPendingStates[ordinal] ?? SubtitleOCRPendingState()
        var closed: [SubtitleCue] = []
        defer {
            closed.append(contentsOf: pending.expired(asOf: playhead))
            subtitleOCRPendingStates[ordinal] = pending
        }
        let plan = SubtitleOverlayDrainer.drainPlan(
            cursor: subtitleOCRCursors[ordinal], playhead: playhead,
            lead: Self.subtitleOCRLeadSeconds,
            backscan: Self.subtitleDrainBackscanSeconds,
            jumpThreshold: Self.subtitleDrainJumpThresholdSeconds)
        let window: (from: Double, through: Double)
        switch plan {
        case .idle:
            subtitleOCRCursors[ordinal]?.lastPlayhead = playhead
            return closed
        case .decode(let from, let through):
            window = (from, through)
        case .resetAndDecode(let from, let through):
            subtitleOCRDecoder = nil
            pending = SubtitleOCRPendingState()
            window = (from, through)
        }
        if subtitleOCRDecoder == nil {
            subtitleOCRDecoder = makeSubtitleDrainDecoder(streamIndex: streamIndex)
        }
        guard let decoder = subtitleOCRDecoder else { return closed }
        let entries = packetStore.entries(streamIndex: streamIndex,
                                          from: window.from, through: window.through)
        let batch = entries.prefix(Self.subtitleOCRMaxPacketsPerTick)
        var lastDecoded = subtitleOCRCursors[ordinal]?.lastDecodedPts
        for entry in batch {
            if let event = Self.decodeStoredSubtitlePacket(entry, with: decoder) {
                closed.append(contentsOf: pending.consume(
                    eventPts: entry.ptsSeconds, cues: event.cues, trimAt: event.pgsTrimAt))
            }
            lastDecoded = entry.ptsSeconds
        }
        if case .resetAndDecode = plan, batch.isEmpty {
            lastDecoded = window.from
        }
        subtitleOCRCursors[ordinal] = SubtitleDrainCursor(
            lastDecodedPts: lastDecoded ?? window.from, lastPlayhead: playhead)
        return closed
    }

    /// #88 external .sup path: fill the needsOCR ordinal's store from the overlay sidecar
    /// decode's OWN image cues (no second download); markFinished so the PiP pre-fill and the
    /// whole-file .vtt handler see complete coverage.
    func startSidecarOCRFillIfNeeded(externalTrackID: Int?, cues: [SubtitleCue]) {
        guard let id = externalTrackID,
              let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: id, in: nativeSubtitleTrackTable),
              nativeSubtitleTrackTable[ordinal].needsOCR,
              let store = nativeStore(atOrdinal: ordinal),
              !store.isFinished else { return }
        let language = nativeSubtitleTrackTable[ordinal].language
        subtitleOCRSidecarFillTask?.cancel()
        EngineLog.emit("[SubtitleOCR] sidecar fill starting: track=\(id) cues=\(cues.count)", category: .engine)
        subtitleOCRSidecarFillTask = Task.detached(priority: .utility) {
            SubtitleImageOCR.appendRecognized(cues: cues, language: language, to: store)
            if !Task.isCancelled { store.markFinished() }
        }
    }
}
